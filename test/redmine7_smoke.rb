require 'minitest/autorun'
require 'action_controller/test_case'

class StartpageSmokeTest < ActionController::TestCase
  setup do
    raise 'Run only against the upgraded local db service' unless ActiveRecord::Base.connection_db_config.host == 'db'
    raise 'Local Slack delivery must remain disabled' unless ENV['REDMINE_SLACK_DELIVERY_ENABLED'] == '0'

    @connection = ActiveRecord::Base.connection
    @connection.begin_transaction(joinable: false)
    @routes = Rails.application.routes
    @user = User.active.where(admin: true).first!
    @request.session[:user_id] = @user.id
    @request.session[:tk] = @user.generate_session_token
    @request.session[:sudo_timestamp] = Time.now.to_i
    User.current = @user
    @perform_deliveries = ActionMailer::Base.perform_deliveries
    ActionMailer::Base.perform_deliveries = false
    Setting.login_required = '1'
    Setting.plugin_redmine_startpage = {
      'startpage_active' => '1', 'startpage_controller' => 'my',
      'startpage_action' => 'page', 'startpage_id' => '',
      'startpage_argname' => '', 'startpage_argvalue' => ''
    }
  end

  teardown do
    @connection.rollback_transaction if @connection
    Setting.clear_cache
    User.current = nil
    ActionMailer::Base.perform_deliveries = @perform_deliveries
  end

  def configure_startpage(attributes)
    Setting.plugin_redmine_startpage = Setting.plugin_redmine_startpage.merge(attributes)
  end

  def make_anonymous
    @request.session.clear
    User.current = User.anonymous
  end
end

class StartpageWelcomeSmokeTest < StartpageSmokeTest
  tests WelcomeController

  def test_active_home_redirects_to_my_page
    assert_equal '0.2.0', Redmine::Plugin.find(:redmine_startpage).version
    get :index
    assert_redirected_to '/my/page'
  end

  def test_disabled_values_keep_native_home
    [false, nil, 0, '0', 'false', 'off', ''].each do |value|
      configure_startpage('startpage_active' => value)
      get :index
      assert_response :success
      assert_select 'h2', text: I18n.t(:label_home)
    end
  end

  def test_blank_destination_keeps_native_home
    configure_startpage('startpage_controller' => ' ')
    get :index
    assert_response :success
  end

  def test_invalid_route_keeps_native_home
    configure_startpage('startpage_controller' => 'startpage_missing_fixture', 'startpage_action' => 'index')
    get :index
    assert_response :success
  end

  def test_identifier_and_extra_argument_route_to_project_wiki
    configure_startpage('startpage_controller' => 'wiki', 'startpage_action' => 'show',
      'startpage_id' => 'Knowledgebase', 'startpage_argname' => 'project_id',
      'startpage_argvalue' => 'knowledgebase')
    get :index
    assert_redirected_to '/projects/knowledgebase/wiki/Knowledgebase'
  end

  def test_repeated_preparation_does_not_duplicate_callback
    3.times { Rails.application.reloader.prepare! }
    assert_equal 1, WelcomeController.ancestors.count { |ancestor| ancestor == WelcomeControllerPatch }
    assert_equal 1, WelcomeController._process_action_callbacks.count { |callback| callback.filter == :redirect_to_configured_startpage }
    get :index
    assert_redirected_to '/my/page'
  end

  def test_anonymous_home_requires_login_before_redirect
    make_anonymous
    get :index
    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal '/login', location.path
    back_url = URI.decode_www_form(location.query).to_h.fetch('back_url')
    assert_equal '/', URI.parse(back_url).path
  end
end

class StartpageMyPageSmokeTest < StartpageSmokeTest
  tests MyController

  def test_destination_renders_without_redirect_loop
    get :page
    assert_response :success
    assert_select 'h2', text: I18n.t(:label_my_page)
  end
end

class StartpageAccountSmokeTest < StartpageSmokeTest
  tests AccountController

  def login_fixture(back_url = nil)
    user = User.new(login: 'startpage-fixture-user', firstname: 'Startpage', lastname: 'Fixture',
      mail: 'startpage-fixture@example.invalid', language: 'en', status: User::STATUS_ACTIVE)
    user.password = user.password_confirmation = 'StartpageFixture_2026!'
    user.save!
    make_anonymous
    get :login
    assert_response :success
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    post :login, params: {username: user.login, password: 'StartpageFixture_2026!',
      authenticity_token: csrf_token, back_url: back_url}
    assert_equal user.id, @request.session[:user_id]
  end

  def test_direct_login_keeps_native_my_page_default
    login_fixture
    assert_redirected_to '/my/page'
  end

  def test_login_preserves_direct_return_url
    login_fixture('/issues')
    assert_redirected_to '/issues'
  end
end

class StartpageSettingsSmokeTest < StartpageSmokeTest
  tests SettingsController

  def test_admin_settings_form_preserves_six_fields
    get :plugin, params: {id: 'redmine_startpage'}
    assert_response :success
    assert_select 'input[name="settings[startpage_active]"][type="checkbox"][checked]', count: 1
    assert_select 'input[name="settings[startpage_controller]"][value="my"]', count: 1
    assert_select 'input[name="settings[startpage_action]"][value="page"]', count: 1
    %w[startpage_id startpage_argname startpage_argvalue].each do |field|
      assert_select "input[name=\"settings[#{field}]\"]", count: 1
    end
  end
end
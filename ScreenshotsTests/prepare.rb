require 'xcodeproj'
project = Xcodeproj::Project.open('ios/CalAI.xcodeproj')
app = project.targets.find { |t| t.name == 'CalAI' }
test = project.new_target(:ui_test_bundle, 'ScreenshotsTests', :ios, '17.0')
test.add_dependency(app)
group = project.main_group.new_group('ScreenshotsTests', '../ScreenshotsTests')
file = group.new_file('ScreenshotsTests.swift')
test.source_build_phase.add_file_reference(file)
test.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'ScreenshotsTests'
  config.build_settings['PRODUCT_MODULE_NAME'] = 'ScreenshotsTests'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = ''
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.lightcal.screenshots.tests'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['INFOPLIST_FILE'] = ''
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TEST_TARGET_NAME'] = 'CalAI'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
end
project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][test.uuid] = {'TestTargetID' => app.uuid}
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(test)
scheme.set_launch_target(app)
scheme.add_test_target(test)
scheme.save_as(project.path, 'Screenshots')

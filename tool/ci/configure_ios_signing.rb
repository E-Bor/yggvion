# CI-only settings. apple_release.py backs up and restores the project.
# Profiles belong to each app target, never to CocoaPods/framework targets.
require 'xcodeproj'

abort 'Expected project, team, certificate SHA-1, Runner profile and widget profile' unless ARGV.length == 5
project_path, team, identity, runner_profile, widget_profile = ARGV
project = Xcodeproj::Project.open(project_path)
targets = {
  'Runner' => ['dev.yggvion.yggvion', runner_profile],
  'TrackingWidget' => ['dev.yggvion.yggvion.Tracking', widget_profile],
}
targets.each do |name, (bundle_id, profile)|
  target = project.targets.find { |candidate| candidate.name == name }
  abort "Missing #{name} target" unless target
  release = target.build_configurations.find { |config| config.name == 'Release' }
  abort "Missing #{name} Release configuration" unless release
  settings = release.build_settings
  abort "Unexpected #{name} bundle identifier" unless settings['PRODUCT_BUNDLE_IDENTIFIER'] == bundle_id
  settings.delete_if do |key, _|
    key.match?(/\A(?:CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PROVISIONING_PROFILE|PROVISIONING_PROFILE_SPECIFIER)(?:\[|\z)/)
  end
  settings.merge!({
    'CODE_SIGN_STYLE' => 'Manual',
    'CODE_SIGN_IDENTITY' => identity,
    'CODE_SIGN_IDENTITY[sdk=iphoneos*]' => identity,
    'DEVELOPMENT_TEAM' => team,
    'PROVISIONING_PROFILE_SPECIFIER' => profile,
  })
end
project.save

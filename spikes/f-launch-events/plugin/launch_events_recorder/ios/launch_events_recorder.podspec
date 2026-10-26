Pod::Spec.new do |s|
  s.name             = 'launch_events_recorder'
  s.version          = '0.0.1'
  s.summary          = 'Records the lifecycle events Flutter forwards to a plugin.'
  s.description      = 'A generic sample plugin for winCode spike F.'
  s.homepage         = 'https://github.com/wincode-org/wincode'
  s.license          = { :type => 'MIT' }
  s.author           = { 'winCode' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'launch_events_recorder/Sources/launch_events_recorder/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end

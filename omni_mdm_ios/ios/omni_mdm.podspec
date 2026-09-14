Pod::Spec.new do |s|
  s.name             = 'omni_mdm'
  s.version          = '0.1.0-m0'
  s.summary          = 'Omni MDM iOS stub (MVP Android only)'
  s.homepage         = 'https://github.com/omni-mdm/sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Omni MDM' => 'dev@omni-mdm.local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'SachnoiBridge'
  s.version = package['version']
  s.summary = package['description']
  s.license = 'MIT'
  s.homepage = 'https://github.com/hieuka001/sachnoi-offline'
  s.author = 'hieuka001'
  s.source = { :git => 'https://github.com/hieuka001/sachnoi-offline', :tag => s.version.to_s }
  s.source_files = 'ios/Plugin/**/*.{swift,h,m,c,cc,mm,cpp}'
  s.ios.deployment_target = '13.0'
  s.static_framework = true
  s.dependency 'Capacitor'
  s.dependency 'onnxruntime-objc', '~> 1.20.0'
  s.vendored_libraries = 'ios/Plugin/vendor/libsea_g2p_rs.a'
  s.preserve_paths = 'ios/Plugin/vendor/libsea_g2p_rs.a', 'ios/Plugin/SeaG2p/module.modulemap', 'ios/Plugin/SeaG2p/sea_g2p.h'
  s.pod_target_xcconfig = { 'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/ios/Plugin/SeaG2p' }
  s.swift_version = '5.1'
end

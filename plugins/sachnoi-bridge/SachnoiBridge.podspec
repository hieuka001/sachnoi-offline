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
  # 2.0.0: TTS dùng sherpa-onnx (xcframework tĩnh chính thức của k2-fsa,
  # CI tải về ios/Frameworks trước khi pod install) thay cho onnxruntime-objc
  # + libsea_g2p_rs.a của engine VieNeu tự port đã xoá.
  s.vendored_frameworks = 'ios/Frameworks/sherpa-onnx.xcframework'
  s.libraries = 'c++'
  s.swift_version = '5.1'
end

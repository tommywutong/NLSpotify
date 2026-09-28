platform :ios, '15.0'
inhibit_all_warnings!

install! 'cocoapods', :deterministic_uuids => false

target 'NLSpotify' do
    use_frameworks! :linkage => :static
    pod 'AFNetworking'
    pod 'YYModel'
    pod 'Masonry'
    # pod 'FMDB' (已经光荣下岗)
    pod 'SocketRocket'
    pod 'JXCategoryView'
    pod 'SDWebImage'
    pod 'WCDB.objc', '~> 2.1.16'
    pod 'HysteriaPlayer'
    pod 'IQKeyboardManager'
    pod 'ReactiveObjC'
    pod 'LookinServer', :configurations => ['Debug']
end

# Xcode 27 的 Simulator SDK 仅支持 iOS 15.0 及以上部署目标。
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      # 旧 Podspec 的部署版本低于 Xcode 27 支持范围，统一提升到 iOS 15.0。
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      # AFNetworking 在 Xcode 27 中会把 netinet6/in6.h 判定为私有模块头。
      config.build_settings['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'
      if target.name == 'AFNetworking'
        flags = config.build_settings['OTHER_CFLAGS'] || ['$(inherited)']
        flags << '-fno-modules'
        config.build_settings['OTHER_CFLAGS'] = flags
      end
    end
  end
end
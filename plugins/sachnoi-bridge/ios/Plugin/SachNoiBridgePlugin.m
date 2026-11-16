#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(SachNoiBridgePlugin, "SachNoiBridge",
           CAP_PLUGIN_METHOD(getInfo, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(saveFile, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(ttsVoices, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(ttsSynthesize, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(ttsDiagnostics, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(downloadPack, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(cancelPackDownload, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(packStatus, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(listInstalledPacks, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(deletePack, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(verifyPack, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setNowPlaying, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(updatePlaybackState, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(clearNowPlaying, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(scheduleBackgroundTasks, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(markManifestSeen, CAPPluginReturnPromise);
)

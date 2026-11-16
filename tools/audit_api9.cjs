#!/usr/bin/env node
// Audit the SDK declarations actually used by the unpacked project.
// SDK declaration availability is not a real Huawei device compatibility test.
const fs = require('fs');
const path = require('path');
const ts = require('typescript');
const [sdk, project] = process.argv.slice(2);
if (!sdk || !project) throw new Error('Usage: node audit_api9.cjs SDK9 PROJECT');
const api = path.join(sdk, 'ets/api');
const selectors = {
  '@ohos.app.ability.UIAbility': ['UIAbility'],
  '@ohos.app.ability.wantAgent': ['wantAgent.getWantAgent'],
  '@ohos.resourceschedule.backgroundTaskManager': [
    'backgroundTaskManager.startBackgroundRunning', 'backgroundTaskManager.stopBackgroundRunning',
    'backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK', 'backgroundTaskManager.BackgroundMode.DATA_TRANSFER'],
  '@ohos.router': ['router.pushUrl', 'router.back'],
  '@ohos.deviceInfo': ['deviceInfo.displayVersion', 'deviceInfo.sdkApiVersion'],
  '@ohos.hidebug': ['hidebug.getPss', 'hidebug.getNativeHeapAllocatedSize'],
  '@ohos.promptAction': ['promptAction.showToast', 'promptAction.ShowToastOptions.duration',
    'promptAction.showDialog', 'promptAction.ShowDialogSuccessResponse.index'],
  '@ohos.notificationManager': [
    'notificationManager.requestEnableNotification', 'notificationManager.addSlot',
    'notificationManager.publish', 'notificationManager.cancel',
    'notificationManager.SlotType.OTHER_TYPES', 'notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT'],
  'notification/notificationRequest': [
    'NotificationRequest.autoDeletedTime', 'NotificationRequest.distributedOption', 'DistributedOptions.isDistributed'],
  '@ohos.file.fs': ['accessSync', 'mkdirSync', 'statSync', 'openSync',
    'writeSync', 'closeSync', 'unlinkSync', 'renameSync', 'read', 'write', 'fsync', 'rmdirSync'],
  '@ohos.file.hash': ['hash.hash'],
  '@ohos.file.picker': ['picker.DocumentViewPicker.select', 'picker.DocumentViewPicker.save',
    'picker.DocumentSaveOptions.newFileNames', 'picker.PhotoViewPicker.select',
    'picker.PhotoSelectOptions.MIMEType', 'picker.PhotoSelectOptions.maxSelectNumber',
    'picker.PhotoSelectResult.photoUris', 'picker.PhotoViewMIMETypes.IMAGE_TYPE'],
  '@ohos.util': ['util.TextDecoder', 'util.TextDecoder.decodeWithStream',
    'util.TextEncoder.encodeInto',
    'util.Base64Helper', 'util.Base64Helper.encodeToStringSync', 'util.Base64Helper.decodeSync'],
  '@ohos.request': ['request.downloadFile', 'request.DownloadTask.on'],
  '@ohos.net.http': ['http.createHttp', 'http.HttpRequest.request', 'http.HttpRequest.destroy'],
  '@ohos.multimedia.media': ['media.createAVPlayer', 'media.AVPlayer.fdSrc',
    'media.AVPlayer.on', 'media.AVPlayer.prepare', 'media.AVPlayer.play', 'media.AVPlayer.release'],
  '@ohos.multimedia.image': ['image.createImageSource', 'image.createImagePacker',
    'image.ImageSource.getImageInfo', 'image.ImageSource.createPixelMap', 'image.ImageSource.release',
    'image.PixelMap.scale', 'image.PixelMap.release', 'image.ImagePacker.packing', 'image.ImagePacker.release',
    'image.DecodingOptions.desiredRegion', 'image.DecodingOptions.desiredSize'],
  '@ohos.window': ['window.WindowStage.loadContent'],
  '@ohos.resourceManager': ['resourceManager.ResourceManager.getRawFileContent'],
};
function walkFiles(directory) {
  return fs.readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? walkFiles(file) : [file];
  });
}
const imports = new Set();
for (const file of walkFiles(path.join(project, 'entry/src/main/ets')).filter(f => f.endsWith('.ets'))) {
  for (const match of fs.readFileSync(file, 'utf8').matchAll(/from\s+['"](@ohos\.[^'"]+)['"]/g)) imports.add(match[1]);
}
const modules = [...imports].sort().map(name => ({
  name, exists_in_api9_sdk: fs.existsSync(path.join(api, name + '.d.ts')),
}));
const declarations = [];
for (const [moduleName, wanted] of Object.entries(selectors)) {
  const filename = path.join(api, moduleName + '.d.ts');
  const source = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.Latest, true);
  const collected = new Map();
  function visit(node, names, inherited) {
    const tags = ts.getJSDocTags(node);
    const ownVersions = tags.filter(t => t.tagName.text === 'since')
      .map(t => Number.parseInt(typeof t.comment === 'string' ? t.comment : '', 10)).filter(Number.isFinite);
    const versions = ownVersions.length ? ownVersions : inherited;
    const named = node.name && (ts.isIdentifier(node.name) || ts.isStringLiteral(node.name));
    const scope = named ? [...names, node.name.text] : names;
    const key = scope.join('.');
    if (named && wanted.includes(key)) {
      const record = collected.get(key) || {module: moduleName, declaration: key,
        since: [], system_api: false, deprecated: false, lines: []};
      record.since.push(...versions);
      record.system_api ||= tags.some(t => t.tagName.text === 'systemapi');
      record.deprecated ||= tags.some(t => t.tagName.text === 'deprecated');
      record.lines.push(source.getLineAndCharacterOfPosition(node.getStart()).line + 1);
      collected.set(key, record);
    }
    ts.forEachChild(node, child => visit(child, scope, versions));
  }
  visit(source, [], []);
  for (const selector of wanted) {
    const record = collected.get(selector);
    if (!record) throw new Error(`Missing SDK declaration: ${moduleName}/${selector}`);
    record.since = [...new Set(record.since)].sort((a, b) => a - b);
    record.api9_version_check = record.since.length ?
      record.since.every(n => n <= 9) : null;
    declarations.push(record);
  }
}
const passed = modules.every(m => m.exists_in_api9_sdk) &&
  declarations.every(d => d.api9_version_check === true && !d.system_api);
console.log(JSON.stringify({scope: 'SDK declaration audit, not runtime or every ArkUI member',
  sdk_version_ceiling: 9, modules, declarations, passed}, null, 2));
if (!passed) process.exitCode = 1;

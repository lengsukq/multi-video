import { cp, mkdir, rm, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const rootDir = resolve(scriptDir, '..');
const repoRoot = resolve(rootDir, '../..');
const nodeModules = join(rootDir, 'node_modules');
const distDir = join(rootDir, 'dist');
const vendorsDir = join(distDir, 'vendors');
const videoEffectsDir = resolve(
  repoRoot,
  'packages/flutter_realtime_video_effects/assets/web',
);
const agoraChatMacOSAssetsDir = resolve(
  repoRoot,
  'packages/flutter_realtime_chat_agora/macos/Resources',
);
const agoraChatMacOSSwiftPMDir = resolve(
  repoRoot,
  'packages/flutter_realtime_chat_agora/macos/flutter_realtime_chat_agora/Sources/flutter_realtime_chat_agora/Resources',
);
const videoEffectsModelSource = join(
  rootDir,
  'assets/video-effects/models/selfie_segmenter_landscape.tflite',
);

await rm(distDir, { recursive: true, force: true });
await mkdir(vendorsDir, { recursive: true });
await rm(videoEffectsDir, { recursive: true, force: true });
await mkdir(videoEffectsDir, { recursive: true });

const vendorFiles = [
  ['agora-rtc-sdk-ng/AgoraRTC_N-production.js', 'agora-rtc-sdk.js'],
  ['trtc-sdk-v5/trtc.js', 'trtc.js'],
  [
    'amazon-ivs-web-broadcast/dist/amazon-ivs-web-broadcast.js',
    'amazon-ivs-web-broadcast.js',
  ],
];

for (const [source, target] of vendorFiles) {
  await cp(join(nodeModules, source), join(vendorsDir, target));
}

await cp(
  join(nodeModules, 'trtc-sdk-v5/assets'),
  join(vendorsDir, 'trtc-assets'),
  { recursive: true },
);

await build({
  absWorkingDir: rootDir,
  entryPoints: ['src/aliyun-entry.js'],
  outfile: join(vendorsDir, 'aliyun-rtc-sdk.js'),
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: ['es2020'],
  minify: true,
  legalComments: 'eof',
});

await build({
  absWorkingDir: rootDir,
  entryPoints: ['src/video-effects-entry.js'],
  outfile: join(videoEffectsDir, 'vision.js'),
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: ['es2020'],
  minify: true,
  legalComments: 'eof',
});

await cp(
  join(nodeModules, '@mediapipe/tasks-vision/wasm'),
  join(videoEffectsDir, 'wasm'),
  { recursive: true },
);
await mkdir(join(videoEffectsDir, 'models'), { recursive: true });
await cp(
  videoEffectsModelSource,
  join(videoEffectsDir, 'models/selfie_segmenter_landscape.tflite'),
);
await cp(join(rootDir, 'assets/video-effects/models/blaze_face_short_range.tflite'), join(videoEffectsDir, 'models/blaze_face_short_range.tflite'));

const processedBridge = await readFile(resolve(repoRoot, 'packages/flutter_realtime_processed_video/web/processed-video-bridge.js'), 'utf8');
await mkdir(resolve(repoRoot, 'packages/flutter_realtime_processed_video/assets'), {recursive: true});
await writeFile(resolve(repoRoot, 'packages/flutter_realtime_processed_video/assets/processed-video-bridge.js'), processedBridge);
await writeFile(join(videoEffectsDir, 'video-effects-bridge.js'), processedBridge + '\n' + await readFile(resolve(repoRoot, 'packages/flutter_realtime_video_effects/web/video-effects-bridge.js'), 'utf8'));
await cp(
  join(rootDir, 'assets/video-effects/MODEL_SOURCE.md'),
  join(videoEffectsDir, 'MODEL_SOURCE.md'),
);

await build({
  absWorkingDir: rootDir,
  entryPoints: ['src/chime-entry.js'],
  outfile: join(vendorsDir, 'chime-sdk.js'),
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: ['es2020'],
  minify: true,
  legalComments: 'eof',
  plugins: [{
    name: 'chime-meeting-only-barrel',
    setup(builder) {
      const meetingTask = join(
        nodeModules,
        'amazon-chime-sdk-js/build/task/PromoteToPrimaryMeetingTask.js',
      );
      builder.onResolve({ filter: /^\.\.$/ }, (args) =>
        args.importer.endsWith(
          '/amazon-chime-sdk-js/build/task/PromoteToPrimaryMeetingTask.js',
        )
          ? { path: join(rootDir, 'src/chime-index-shim.js') }
          : undefined,
      );
    },
  }],
});

await build({
  absWorkingDir: rootDir,
  entryPoints: ['src/chat-provider-entry.js'],
  outfile: join(vendorsDir, 'realtime-chat-provider-bridge.js'),
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: ['es2020'],
  minify: true,
  legalComments: 'eof',
});

await mkdir(agoraChatMacOSAssetsDir, { recursive: true });
await mkdir(agoraChatMacOSSwiftPMDir, { recursive: true });
const agoraChatMacOSBridgePath = join(
  agoraChatMacOSAssetsDir,
  'agora_chat_macos.js',
);
await build({
  absWorkingDir: rootDir,
  entryPoints: ['src/agora-chat-macos-entry.js'],
  outfile: agoraChatMacOSBridgePath,
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: ['es2020'],
  minify: true,
  legalComments: 'eof',
});
await cp(
  agoraChatMacOSBridgePath,
  join(agoraChatMacOSSwiftPMDir, 'agora_chat_macos.js'),
);

await build({ absWorkingDir: rootDir, entryPoints: ['src/bridge.js'], outfile: join(distDir, 'media-provider-bridge.js'), bundle: true, platform: 'browser', format: 'iife', target: ['es2020'], legalComments: 'eof' });

const licensesDir = join(distDir, 'licenses');
await mkdir(licensesDir, 'recursive' ? { recursive: true } : undefined);
for (const [packageName, licensePrefix] of [
  ['@mediapipe/tasks-vision', 'mediapipe-tasks-vision'],
  ['@tencentcloud/chat', 'tencent-cloud-chat'],
  ['tim-upload-plugin', 'tim-upload-plugin'],
  ['agora-chat', 'agora-chat'],
  ['agora-rtc-sdk-ng', 'agora-rtc-sdk-ng'],
  ['aliyun-rtc-sdk', 'aliyun-rtc-sdk'],
  ['amazon-chime-sdk-js', 'amazon-chime-sdk-js'],
  ['amazon-ivs-chat-messaging', 'amazon-ivs-chat-messaging'],
  ['amazon-ivs-web-broadcast', 'amazon-ivs-web-broadcast'],
  ['trtc-sdk-v5', 'trtc-sdk-v5'],
  ['eventemitter3', 'eventemitter3'],
]) {
  const packageDir = join(nodeModules, packageName);
  for (const name of ['LICENSE', 'LICENSE.txt', 'NOTICE']) {
    try {
      await cp(join(packageDir, name), join(licensesDir, `${licensePrefix}-${name}`));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}


await import('./build-optional-providers.mjs');

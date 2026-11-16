import image from '@ohos.multimedia.image';
import util from '@ohos.util';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import { parseMinimapRoi } from './MinimapTracker';
import { inspectCloudPixels } from './CloudImageQuality';
import { padMinimapRgba } from './MinimapCrop';

export interface CloudImage {
  url: string;
  geometry: string;
  capturedAt: number;
  frameId: string;
  sourcePreview?: string;
  sourceAspectRatio?: number;
  cropBounds?: number[];
  issue?: string;
}

export async function cropCloudMinimap(bytes: Uint8Array, roi: string,
  capturedAt: number, frameId: string, square: boolean = false): Promise<CloudImage> {
  const region = parseMinimapRoi(roi);
  if (!bytes.byteLength || bytes.byteLength > 16 * 1024 * 1024) {
    throw new Error('截图为空或超过16 MiB');
  }
  const encoded = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const source = image.createImageSource(encoded);
  const packer = image.createImagePacker();
  let pixels: image.PixelMap | undefined;
  let padded: image.PixelMap | undefined;
  try {
    const info = await source.getImageInfo();
    const size = info.size;
    if (size.width <= 0 || size.height <= 0 || size.width * size.height > 36000000) {
      throw new Error('截图尺寸无效或过大');
    }
    const width = Math.floor(size.width * region[2]);
    const height = Math.floor(size.height * region[3]);
    const left = Math.floor(size.width * region[0]);
    const top = Math.floor(size.height * region[1]);
    if (width < 64 || height < 64) throw new Error('小地图裁剪不足64像素，请重新设置裁剪范围');
    pixels = await source.createPixelMap({ editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
    await pixels.crop({ x: left, y: top,
      size: { width: width, height: height } });
    const scale = Math.min(1, 512 / Math.max(width, height));
    if (scale < 1) await pixels.scale(scale, scale);
    const croppedSize = (await pixels.getImageInfo()).size;
    const croppedPixels = new ArrayBuffer(croppedSize.width * croppedSize.height * 4);
    await pixels.readPixelsToBuffer(croppedPixels);
    const croppedBlack = inspectCloudPixels(new Uint8Array(croppedPixels), croppedSize.width, croppedSize.height).black;
    let issue = '';
    if (croppedBlack) {
      const originalBlack = await isCloudSourceBlack(encoded, size.width, size.height);
      issue = originalBlack ? '原始录屏帧接近全黑，未发送云端；请检查系统授权和采集状态。' :
        '原始帧有内容，但小地图区域全黑，未发送云端；请对照原始帧检查采集方向和裁剪位置。';
    }
    if (square && croppedSize.width !== croppedSize.height) {
      const side = Math.max(croppedSize.width, croppedSize.height);
      const buffer = padMinimapRgba(new Uint8Array(croppedPixels), croppedSize.width, croppedSize.height);
      padded = await image.createPixelMap(buffer.buffer, { size: { width: side, height: side },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888, pixelFormat: image.PixelMapFormat.RGBA_8888 });
    }
    const packed = new Uint8Array(await packer.packing(padded || pixels, { format: 'image/jpeg', quality: 92 }));
    if (packed.byteLength > 1024 * 1024) throw new Error('小地图图片过大');
    const mime = /^image\/[a-zA-Z0-9.+-]+$/.test(info.mimeType) ? info.mimeType : 'image/png';
    const encoder = new util.Base64Helper();
    return {
      url: `data:image/jpeg;base64,${encoder.encodeToStringSync(packed)}`,
      sourcePreview: `data:${mime};base64,${encoder.encodeToStringSync(bytes)}`,
      sourceAspectRatio: size.width / size.height,
      cropBounds: [left / size.width, top / size.height, width / size.width, height / size.height],
      issue: issue,
      geometry: `${size.width}x${size.height}:${region.join(',')}:${width},${height}:${square ? 'pad' : 'rect'}`,
      capturedAt: capturedAt, frameId: frameId
    };
  } finally {
    await padded?.release();
    await pixels?.release();
    await source.release();
    await packer.release();
  }
}

async function isCloudSourceBlack(encoded: ArrayBuffer, width: number, height: number): Promise<boolean> {
  const verifier = image.createImageSource(encoded);
  let sample: image.PixelMap | undefined;
  try {
    const sampleWidth = Math.min(256, width);
    sample = await verifier.createPixelMap({ desiredSize: { width: sampleWidth,
      height: Math.max(1, Math.round(height * sampleWidth / width)) },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
    const size = (await sample.getImageInfo()).size;
    const buffer = new ArrayBuffer(size.width * size.height * 4);
    await sample.readPixelsToBuffer(buffer);
    return inspectCloudPixels(new Uint8Array(buffer), size.width, size.height).black;
  } finally {
    await sample?.release();
    await verifier.release();
  }
}

export async function selectCloudScreenshot(): Promise<Uint8Array | undefined> {
  const selected = await new picker.PhotoViewPicker().select({
    MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1
  });
  if (!selected.photoUris.length) return undefined;
  const file = fs.openSync(selected.photoUris[0], fs.OpenMode.READ_ONLY);
  try {
    const size = fs.statSync(file.fd).size;
    if (!size || size > 16 * 1024 * 1024) throw new Error('请选择不超过16 MiB的截图');
    const bytes = new Uint8Array(size);
    let received = 0;
    while (received < size) {
      const chunk = new ArrayBuffer(Math.min(size - received, 1024 * 1024));
      const count = await fs.read(file.fd, chunk, { length: chunk.byteLength });
      if (count <= 0 || count > chunk.byteLength) throw new Error('截图读取不完整');
      bytes.set(new Uint8Array(chunk, 0, count), received);
      received += count;
    }
    return bytes;
  } finally {
    fs.closeSync(file);
  }
}

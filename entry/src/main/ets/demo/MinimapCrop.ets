export const DEFAULT_MINIMAP_ROI: string = '0.025,0,0.168,0.325';
export const LEGACY_MINIMAP_ROI: string = '0,0,0.195,0.35';

export function padMinimapRgba(source: Uint8Array, width: number, height: number): Uint8Array {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 ||
    width > 512 || height > 512 || source.length !== width * height * 4) {
    throw new Error('小地图补边像素尺寸无效');
  }
  const side = Math.max(width, height);
  const padded = new Uint8Array(side * side * 4);
  for (let offset = 0; offset < padded.length; offset += 4) {
    padded[offset] = 24;
    padded[offset + 1] = 24;
    padded[offset + 2] = 24;
    padded[offset + 3] = 255;
  }
  const left = Math.floor((side - width) / 2);
  const top = Math.floor((side - height) / 2);
  for (let row = 0; row < height; ++row) {
    padded.set(source.subarray(row * width * 4, (row + 1) * width * 4), ((top + row) * side + left) * 4);
  }
  return padded;
}

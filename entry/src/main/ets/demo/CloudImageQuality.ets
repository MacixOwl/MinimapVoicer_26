export interface CloudImageBounds {
  x: number;
  y: number;
  width: number;
  height: number;
  black: boolean;
}

export function inspectCloudPixels(pixels: Uint8Array, width: number, height: number): CloudImageBounds {
  if (pixels.length !== width * height * 4 || width < 1 || height < 1) {
    throw new Error('截图像素读取失败');
  }
  let left = width;
  let top = height;
  let right = -1;
  let bottom = -1;
  let visible = 0;
  for (let row = 0; row < height; row++) {
    for (let column = 0; column < width; column++) {
      const offset = (row * width + column) * 4;
      if (Math.max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) <= 18) continue;
      visible++;
      left = Math.min(left, column);
      right = Math.max(right, column);
      top = Math.min(top, row);
      bottom = Math.max(bottom, row);
    }
  }
  const black = visible < Math.max(1, width * height * 0.002);
  if (black || right - left + 1 < width * 0.2 || bottom - top + 1 < height * 0.2) {
    return { x: 0, y: 0, width: width, height: height, black: black };
  }
  const marginX = Math.ceil(width * 0.02);
  const marginY = Math.ceil(height * 0.02);
  left = left >= marginX ? Math.max(0, left - 1) : 0;
  top = top >= marginY ? Math.max(0, top - 1) : 0;
  right = width - 1 - right >= marginX ? Math.min(width - 1, right + 1) : width - 1;
  bottom = height - 1 - bottom >= marginY ? Math.min(height - 1, bottom + 1) : height - 1;
  return { x: left, y: top, width: right - left + 1, height: bottom - top + 1, black: false };
}

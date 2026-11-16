declare module 'libgamevoice.so' {
  interface ScreenFrame {
    bytes: ArrayBuffer;
    id: string;
    capturedAt: number;
  }
  interface GameVoice {
    start(filesDir: string, modelJson: string, peer: string): Promise<string>;
    stop(): Promise<string>;
    synthesize(text: string, dataParent: string): Promise<ArrayBuffer>;
    screenStatus(): Promise<string>;
    startScreen(cacheDir: string, uploadOrigin: string, intervalMs: number): Promise<string>;
    stopScreen(): Promise<string>;
    readScreen(after: string): Promise<ScreenFrame | undefined>;
  }
  const gamevoice: GameVoice;
  export default gamevoice;
}

declare module 'libphonetts.so' {
  interface PhoneTts {
    initialize(directory: string): Promise<void>;
    synthesize(text: string): Promise<ArrayBuffer>;
    release(): Promise<void>;
  }
  const phonetts: PhoneTts;
  export default phonetts;
}

declare module 'libphonecapture.so' {
  interface CaptureFrame {
    bytes: ArrayBuffer;
    id: string;
    capturedAt: number;
  }
  interface PhoneCapture {
    screenStatus(): Promise<string>;
    startScreen(cacheDir: string, origin: string, intervalMs: number, width: number, height: number): Promise<string>;
    stopScreen(): Promise<string>;
    readScreen(after: string): Promise<CaptureFrame | undefined>;
  }
  const phonecapture: PhoneCapture;
  export default phonecapture;
}

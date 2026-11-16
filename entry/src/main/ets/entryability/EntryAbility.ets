import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { PhoneScreen } from '../demo/PhoneScreen';
import { CloudPhoneScreen } from '../demo/CloudPhoneScreen';
import { CaptureFeedback } from '../demo/CaptureFeedback';

export default class EntryAbility extends UIAbility {
  onForeground(): void {
    CaptureFeedback.setForeground(true);
  }
  onBackground(): void {
    CaptureFeedback.setForeground(false);
  }
  onDestroy(): void {
    void CaptureFeedback.stop();
    void PhoneScreen.stop();
    void CloudPhoneScreen.stop();
  }
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/CloudBattle', (error) => {
      if (error.code) {
        console.error(`GameVoice: loadContent failed (${error.code}): ${error.message}`);
      }
    });
  }
}

import common from '@ohos.app.ability.common';
import picker from '@ohos.file.picker';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { ModelStorage } from '../demo/ModelStorage';
import { ROCKCHIP_MOCK_ONLY } from '../demo/DemoMode';

@Entry
@Component
struct Models {
  @State private busy: boolean = true;
  @State private modelText: string = '正在检查应用内的模型文件……';
  @State private complete: boolean = false;
  @State private exportUri: string = '';
  @State private importUri: string = '';
  @State private status: string = '卸载前可将视觉模型保存为备份，重装后手动选择备份恢复。';
  private storage?: ModelStorage;
  private active: boolean = true;

  aboutToAppear(): void {
    if (ROCKCHIP_MOCK_ONLY) {
      this.modelText = '当前版本已关闭视觉模型下载、恢复及本机推理入口。';
      this.status = '请返回首页测试瑞芯微模拟转发与手机语音播报。';
      return;
    }
    this.active = true;
    this.storage = new ModelStorage(getContext(this) as common.UIAbilityContext);
    void this.initialize();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.storage?.cancel();
  }

  private async refresh(): Promise<void> {
    const result = await this.storage!.status();
    this.modelText = result.text;
    this.complete = result.complete;
  }

  private async initialize(): Promise<void> {
    try {
      await this.storage!.recover();
      await this.refresh();
    } catch (error) {
      this.status = `模型检查失败：${(error as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  private async exportModel(): Promise<void> {
    if (this.busy || !this.complete) return;
    this.busy = true;
    this.exportUri = '';
    this.importUri = '';
    this.status = '请在系统文件选择器中选择备份保存位置，建议放在“下载”或“文档”。';
    try {
      const uris = await new picker.DocumentViewPicker().save({
        newFileNames: ['gamevoice-qwen3.5-0.8b-q4.gvb']
      });
      if (!this.active) return;
      if (uris.length !== 1) {
        this.status = '已取消备份。';
        return;
      }
      this.exportUri = uris[0];
      this.status = '已选择保存位置。请点击“开始备份”，等待完成后再卸载。';
    } catch (error) {
      this.status = `选择保存位置失败：${(error as Error).message}。` +
        '若系统不提供文档保存界面，此手机暂不可使用该备份入口。';
    } finally {
      this.busy = false;
    }
  }

  private async writeBackup(): Promise<void> {
    if (this.busy || !this.exportUri) return;
    this.busy = true;
    try {
      // API9 documentation recommends opening the URI from a later user action,
      // after the picker has returned and its temporary grant is ready.
      await this.storage!.exportBackup(this.exportUri, (text: string) => { this.status = text; });
      this.status = '备份完成。请在文件管理器确认 .gvb 文件已保存，再卸载应用；保留此文件即可离线恢复模型。';
    } catch (error) {
      this.status = `备份未完成：${(error as Error).message}。请勿用未完成的备份替代模型。`;
    } finally {
      this.exportUri = '';
      this.busy = false;
    }
  }

  private async importModel(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.exportUri = '';
    this.importUri = '';
    try {
      this.status = '请选择此前保存的 .gvb 备份文件。';
      const uris = await new picker.DocumentViewPicker().select();
      if (!this.active) return;
      if (uris.length !== 1) {
        this.status = '已取消恢复。';
        return;
      }
      this.importUri = uris[0];
      this.status = '已选择备份文件。请点击“开始恢复”，校验后才会使用。';
    } catch (error) {
      this.status = `选择备份失败：${(error as Error).message}。` +
        '若系统不提供文档选择界面，此手机暂不可使用该恢复入口。';
    } finally {
      this.busy = false;
    }
  }

  private async restoreBackup(): Promise<void> {
    if (this.busy || !this.importUri) return;
    this.busy = true;
    try {
      if (this.complete) {
        const answer = await promptAction.showDialog({
          title: '恢复模型备份',
          message: '校验成功后将替换当前视觉模型；校验失败会保留原有模型。继续恢复？',
          buttons: [{ text: '取消', color: '#495970' }, { text: '恢复模型', color: '#18644F' }]
        });
        if (!this.active || answer.index !== 1) return;
      }
      await this.storage!.importBackup(this.importUri, (text: string) => { this.status = text; });
      await this.refresh();
      this.status = '恢复完成，全部模型 SHA256 校验通过。返回首页即可使用，无需再次下载。';
    } catch (error) {
      this.status = `恢复未完成：${(error as Error).message}。`;
    } finally {
      this.importUri = '';
      this.busy = false;
    }
  }

  private async deleteModel(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const answer = await promptAction.showDialog({
        title: '删除已下载的视觉模型？',
        message: '删除后需要重新下载约 704 MiB，或从 .gvb 备份恢复。已导出的备份和内置语音模型会保留。',
        buttons: [{ text: '取消', color: '#495970' }, { text: '删除模型', color: '#A03C43' }]
      });
      if (!this.active || answer.index !== 1) return;
      await this.storage!.deleteDownloaded();
      await this.refresh();
      this.status = '应用内已下载的视觉模型及未完成下载文件已删除。';
    } catch (error) {
      this.status = `删除未完成：${(error as Error).message}`;
      await this.refresh();
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('模型存储与卸载').fontSize(28).fontWeight(FontWeight.Bold)
        Text(this.modelText).fontSize(15).fontColor('#495970')
        Button('卸载前：保存模型备份').width('100%').enabled(!this.busy && this.complete)
          .onClick(() => { void this.exportModel(); })
        if (this.exportUri) {
          Button('开始备份 · 约704 MiB').width('100%').enabled(!this.busy)
            .onClick(() => { void this.writeBackup(); })
        }
        Button('重装后：从备份恢复').width('100%').enabled(!this.busy)
          .onClick(() => { void this.importModel(); })
        if (this.importUri) {
          Button('开始恢复 · 校验后使用').width('100%').enabled(!this.busy)
            .onClick(() => { void this.restoreBackup(); })
        }
        Text('备份约 704 MiB，不包含截图或账号。请保存到系统文件选择器提供的个人文件位置，' +
          '不要放入应用私有目录。恢复需要约 704 MiB 临时空间，请保持此页打开直到操作完成。')
          .fontSize(14).fontColor('#495970')
        Button('删除已下载的视觉模型').width('100%').backgroundColor('#A03C43').enabled(!this.busy)
          .onClick(() => { void this.deleteModel(); })
        Text('普通卸载由系统执行，会删除应用私有目录中的视觉模型和语音模型释放副本。' +
          '应用无法在系统卸载时弹出保留询问；请先完成备份。重装后语音模型随安装包恢复，' +
          '视觉模型可从备份导入。覆盖安装且保留应用数据时，可复用现有模型。')
          .fontSize(14).fontColor('#495970')
        Text('文件选择器需手机系统支持。应用只检查自己的模型目录；公共目录中的备份需你主动选择。')
          .fontSize(14).fontColor('#495970')
        Text(this.status).fontSize(16)
        Button('返回首页').enabled(!this.busy).onClick(() => { router.back(); })
      }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor('#F3F6FB')
  }
}

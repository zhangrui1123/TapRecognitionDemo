import router from '@ohos.router';

@Entry
@Component
struct ResultPage {
  @State userName: string = '';
  @State actionLabel: string = '';
  @State sampleCount: number = 0;
  @State filePath: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.userName = (params?.userName as string) ?? '';
    this.actionLabel = (params?.actionLabel as string) ?? '';
    this.sampleCount = (params?.sampleCount as number) ?? 0;
    this.filePath = (params?.filePath as string) ?? '';
  }

  build() {
    Column() {
      Text('✓')
        .fontSize(72)
        .fontColor($r('app.color.recording_color'))
        .margin({ top: 80, bottom: 16 })

      Text($r('app.string.collection_done'))
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8 })

      Text(`${this.userName} · ${this.actionLabel}`)
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 4 })

      Text('CSV saved with English filename and action_label tag')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 32 })

      Column({ space: 10 }) {
        Text(`采样条数：${this.sampleCount}`)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text('文件路径：')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        Text(this.filePath)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .lineHeight(20)
      }
      .width('86%')
      .padding(16)
      .backgroundColor(Color.White)
      .borderRadius(12)

      Blank()

      Button($r('app.string.back_home'))
        .width('86%')
        .height(52)
        .fontSize(18)
        .backgroundColor($r('app.color.primary_color'))
        .borderRadius(26)
        .margin({ bottom: 48 })
        .onClick(() => {
          router.replaceUrl({ url: 'pages/Index' });
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
  }
}

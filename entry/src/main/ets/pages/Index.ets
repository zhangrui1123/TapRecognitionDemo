import router from '@ohos.router';

@Entry
@Component
struct Index {
  build() {
    Column() {
      Text($r('app.string.home_title'))
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 96, bottom: 12 })

      Text($r('app.string.home_subtitle'))
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 64 })

      Column({ space: 16 }) {
        Button($r('app.string.open_demo'))
          .width('86%')
          .height(56)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.primary_color'))
          .borderRadius(28)
          .onClick(() => {
            router.pushUrl({ url: 'pages/DemoPage' });
          })

        Button($r('app.string.start_collection'))
          .width('86%')
          .height(56)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_color'))
          .backgroundColor(Color.White)
          .borderRadius(28)
          .borderWidth(1)
          .borderColor($r('app.color.primary_color'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/CollectionSetupPage' });
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Blank()

      Text($r('app.string.home_hint'))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .width('80%')
        .margin({ bottom: 48 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
  }
}

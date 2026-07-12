@Component
export struct CountdownRingView {
  /** 剩余比例 0~1，1 为完整圆，0 为消失 */
  @Prop remainingRatio: number = 1;
  @Prop countdownValue: number = 3;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Progress({
        value: Math.max(0, Math.min(100, this.remainingRatio * 100)),
        total: 100,
        type: ProgressType.Ring,
      })
        .width(260)
        .height(260)
        .style({
          strokeWidth: 18,
          enableSmoothEffect: true,
        })
        .color($r('app.color.countdown_color'))
        .backgroundColor($r('app.color.countdown_ring_track'))

      Column({ space: 2 }) {
        Text(`${this.countdownValue}`)
          .fontSize(96)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.countdown_color'))

        Text('秒')
          .fontSize(22)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width(280)
    .height(280)
  }
}

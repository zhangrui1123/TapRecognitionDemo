/**
 * 仿小红书「京都七日游」帖子详情页（前台展示内容，自包含）。
 * 顶部自定义导航 → 图片轮播 → 正文/Tips/标签/评论 → 底部互动栏。
 */
import { ImageItem, DaySection } from '../common/Types';

@Component
export struct KyotoPost {
  @Prop viewHeight: number = 900;
  @Prop topInset: number = 44;
  // 点「关注」时回调外层：用于显隐调试面板
  onFollowTap: () => void = () => {};
  // 顶部返回箭头回调（由外层处理路由）
  onBackTap: () => void = () => {};
  @State private currentImage: number = 0;
  @State private liked: boolean = false;
  @State private collected: boolean = false;

  private images: ImageItem[] = [
    { src: $r('app.media.kyoto1'), label: '伏见稻荷大社', cap: '千本鸟居 · 清晨人少' },
    { src: $r('app.media.kyoto2'), label: '清水寺', cap: '二三年坂 · 和服漫步' },
    { src: $r('app.media.kyoto3'), label: '岚山竹林', cap: '渡月桥 · 小火车' },
    { src: $r('app.media.kyoto4'), label: '金阁寺', cap: '镜湖池金箔倒影' },
    { src: $r('app.media.kyoto5'), label: '宇治平等院', cap: '凤凰堂 · 抹茶甜品' },
    { src: $r('app.media.kyoto6'), label: '祇园', cap: '花见小路 · 町屋灯火' }
  ];

  private days: DaySection[] = [
    { h: 'Day 1 · 抵达京都，祇园夜散步',
      b: '关西机场 HARUKA 特急直达京都站约 75 分钟。放下行李先去祇园，沿花见小路看町屋灯火，运气好能偶遇赶场的艺伎。晚餐推荐先斗町的小店，沿鸭川边吃边走超惬意。' },
    { h: 'Day 2 · 清水寺 · 二三年坂',
      b: '早上 8 点前到清水寺避开人潮，舞台远眺京都市景。下山经三年坂、二年坂，石板小路两旁全是和果子与抹茶店。这一带最适合穿和服拍照，记得提前网上预约更便宜。' },
    { h: 'Day 3 · 伏见稻荷 · 千本鸟居',
      b: '千本鸟居建议清晨或傍晚来，红色隧道层层叠叠极其出片。全程登顶来回约 2 小时，半山腰的「四ツ辻」视野最好。山脚的稻荷寿司和烤鹌鹑别错过。' },
    { h: 'Day 4 · 岚山 · 竹林 · 渡月桥',
      b: '嵯峨野小火车提前订票，沿保津川峡谷风景一绝。竹林小径清晨光线最美，野宫神社求姻缘很灵。中午在渡月桥边吃汤豆腐，下午可去天龙寺庭园。' },
    { h: 'Day 5 · 金阁寺 · 龙安寺 · 哲学之道',
      b: '金阁寺金箔倒影在镜湖池上，晴天必拍。龙安寺枯山水石庭值得静坐发呆。傍晚沿哲学之道散步，樱花季两侧花树成隧道，落樱铺满小溪。' },
    { h: 'Day 6 · 宇治 · 平等院 · 抹茶',
      b: '从京都站乘 JR 奈良线约 20 分钟到宇治。平等院凤凰堂就是十円硬币上的那座。沿宇治川走，中村藤吉本店的抹茶荞麦面和生茶冻是此行最爱。' },
    { h: 'Day 7 · 锦市场 · 采购 · 返程',
      b: '「京都厨房」锦市场扫货：渍物、玉子烧、豆乳甜甜圈一路吃过去。再去寺町商店街买点伴手礼，午后从京都站返回关西机场，结束七日漫游。' }
  ];

  private tips: string = '交通：市内地铁巴士一日券 + ICOCA；远郊用 JR。\n住宿：建议住京都站或四条河原町附近，换乘方便。\n季节：3 月底—4 月初樱花、11 月中下旬红叶最美。\n预算：人均含住宿约 ¥6500–9000 / 天。';

  private tags: string[] = ['#京都旅行', '#日本自由行', '#旅行攻略', '#京都美食', '#赏樱攻略'];

  build() {
    Column() {
      // —— 顶部安全区占位：白底延伸到状态栏区域 ——
      Row()
        .width('100%')
        .height(this.topInset)
        .backgroundColor(Color.White)

      // —— 顶部导航（沉浸式，自定义）——
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor(['#1F2937'])
          .width(36)
          .height(36)
          .onClick(() => this.onBackTap())
        Row() {
          Stack() {
            Circle().width(34).height(34).fill('#F472B6')
            Text('游').fontSize(15).fontColor(Color.White).fontWeight(FontWeight.Bold)
          }
          Column() {
            Text('环游酱').fontSize(14).fontColor('#1F2937').fontWeight(FontWeight.Medium)
            Text('旅行博主').fontSize(11).fontColor('#9CA3AF')
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 8 })
        }
        .layoutWeight(1)

        Button('关注')
          .height(32)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#FF2442')
          .borderRadius(16)
          .padding({ left: 16, right: 16 })
          .onClick(() => this.onFollowTap())
        SymbolGlyph($r('sys.symbol.share'))
          .fontSize(20)
          .fontColor(['#1F2937'])
          .margin({ left: 14 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 14, right: 14 })
      .alignItems(VerticalAlign.Center)

      // —— 可滚动主体 ——
      Scroll() {
        Column() {
          // 图片轮播
          Stack({ alignContent: Alignment.TopEnd }) {
            Swiper() {
              ForEach(this.images, (item: ImageItem, idx: number) => {
                Stack({ alignContent: Alignment.BottomStart }) {
                  Image(item.src)
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                  Row() {
                    Text(item.label)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Color.White)
                    Text(item.cap)
                      .fontSize(12)
                      .fontColor('#E5E7EB')
                      .margin({ left: 8 })
                  }
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor('#4D000000')
                  .borderRadius(12)
                  .margin({ left: 12, bottom: 14 })
                }
                .width('100%')
                .height('100%')
              }, (item: ImageItem, idx: number) => idx.toString())
            }
            .height(this.viewHeight * 0.46)
            .loop(false)
            .indicator(false)
            .onChange((index: number) => this.currentImage = index)

            Text(`${this.currentImage + 1} / ${this.images.length}`)
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#66000000')
              .borderRadius(12)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .margin({ top: 14, right: 12 })
          }
          .width('100%')

          // 正文区
          Column() {
            Text('京都七日｜春日漫游全攻略 · 古寺 · 町屋 · 抹茶')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1F2937')
              .width('100%')
              .margin({ bottom: 10 })

            Text('第一次去京都到底怎么玩才不踩雷？这份亲测七日路线，把清水寺、伏见稻荷、岚山、宇治串成一条顺路动线，少走回头路。文末附交通票、住宿和预算，照抄就行。')
              .fontSize(15)
              .lineHeight(24)
              .fontColor('#374151')
              .width('100%')
              .margin({ bottom: 16 })

            ForEach(this.days, (d: DaySection, idx: number) => {
              Column() {
                Text(d.h)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#111827')
                  .width('100%')
                  .margin({ bottom: 6 })
                Text(d.b)
                  .fontSize(15)
                  .lineHeight(24)
                  .fontColor('#374151')
                  .width('100%')
              }
              .width('100%')
              .margin({ bottom: 16 })
            }, (d: DaySection, idx: number) => idx.toString())

            // 实用 Tips
            Column() {
              Text('实用 Tips')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#111827')
                .width('100%')
                .margin({ bottom: 8 })
              Text(this.tips)
                .fontSize(15)
                .lineHeight(26)
                .fontColor('#374151')
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .borderRadius(14)
            .backgroundColor('#FFF7ED')
            .margin({ bottom: 16 })

            // 标签
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.tags, (t: string, idx: number) => {
                Text(t)
                  .fontSize(14)
                  .fontColor('#2563EB')
                  .margin({ right: 12, bottom: 8 })
              }, (t: string, idx: number) => idx.toString())
            }
            .width('100%')
            .margin({ bottom: 10 })

            Row() {
              Text('日本 · 京都')
                .fontSize(13)
                .fontColor('#9CA3AF')
              Blank()
              Text('编辑于 06-15')
                .fontSize(13)
                .fontColor('#9CA3AF')
            }
            .width('100%')
            .margin({ bottom: 18 })

            Divider().color('#F0F0F0')

            Text('共 1,286 条评论')
              .fontSize(14)
              .fontColor('#6B7280')
              .width('100%')
              .margin({ top: 14, bottom: 12 })

            this.Comment('背包客小林', '攻略太详细了！请问七日大概花了多少钱呀～', '128')
            this.Comment('momo', '伏见稻荷清晨去真的绝，谢谢博主提醒', '64')
            this.Comment('抹茶控', '宇治那家中村藤吉我也爱，生茶冻 yyds', '39')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 24 })
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // —— 底部互动栏 ——
      Row() {
        Text('说点什么…')
          .fontSize(14)
          .fontColor('#9CA3AF')
          .layoutWeight(1)
          .height(38)
          .padding({ left: 16 })
          .backgroundColor('#F3F4F6')
          .borderRadius(19)
        this.ActionIcon(
          this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
          this.liked ? '6.9w' : '6.8w', this.liked, '#FF2442',
          () => this.liked = !this.liked)
        this.ActionIcon(
          this.collected ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'),
          '2.1w', this.collected, '#FFB300',
          () => this.collected = !this.collected)
        this.ActionIcon($r('sys.symbol.message'), '1286', false, '#333333', () => {})
      }
      .width('100%')
      .height(58)
      .padding({ left: 14, right: 10, bottom: 6 })
      .alignItems(VerticalAlign.Center)
      .border({ width: { top: 0.5 }, color: '#EEEEEE' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }

  @Builder
  ActionIcon(symbol: Resource, count: string, active: boolean, activeColor: string, onTap: () => void) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(25)
        .fontColor([active ? activeColor : '#333333'])
      Text(count)
        .fontSize(14)
        .fontColor(active ? activeColor : '#333333')
        .margin({ left: 4 })
    }
    .padding({ left: 9, right: 9 })
    .alignItems(VerticalAlign.Center)
    .onClick(onTap)
  }

  @Builder
  Comment(name: string, content: string, likes: string) {
    Row() {
      Stack() {
        Circle().width(32).height(32).fill('#CBD5E1')
        Text(name.substring(0, 1)).fontSize(14).fontColor(Color.White)
      }
      Column() {
        Text(name).fontSize(13).fontColor('#9CA3AF')
        Text(content)
          .fontSize(15)
          .fontColor('#1F2937')
          .lineHeight(22)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      Column() {
        SymbolGlyph($r('sys.symbol.heart')).fontSize(18).fontColor(['#9CA3AF'])
        Text(likes).fontSize(11).fontColor('#9CA3AF').margin({ top: 2 })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 16 })
  }
}

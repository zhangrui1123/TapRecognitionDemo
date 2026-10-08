import router from '@ohos.router';
import {
  ActionConfig,
  ActionType,
  NEGATIVE_ACTION_OPTIONS,
  POSITIVE_ACTION_OPTIONS,
  sanitizeFileNamePart,
} from '../model/SessionTypes';

@Entry
@Component
struct CollectionSetupPage {
  @State collectorId: string = '';
  @State selectedActionType: ActionType | '' = '';
  @State strictSecondTap: boolean = false;

  private isDoubleTapSelected(): boolean {
    return this.selectedActionType === ActionType.KNOCK_TWICE_LEFT ||
      this.selectedActionType === ActionType.KNOCK_TWICE_RIGHT;
  }

  private canStartCollection(): boolean {
    return sanitizeFileNamePart(this.collectorId).length > 0 && this.selectedActionType.length > 0;
  }

  private startCollection(): void {
    if (!this.canStartCollection()) {
      return;
    }
    router.pushUrl({
      url: 'pages/CollectionPage',
      params: {
        userName: sanitizeFileNamePart(this.collectorId),
        actionType: this.selectedActionType,
        strictSecondTap: this.isDoubleTapSelected() && this.strictSecondTap,
      },
    });
  }

  @Builder
  ActionChip(action: ActionConfig) {
    Text(action.label)
      .fontSize(14)
      .fontColor(this.selectedActionType === action.type ? Color.White : $r('app.color.text_primary'))
      .backgroundColor(this.selectedActionType === action.type ? $r('app.color.primary_color') : Color.White)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius(18)
      .borderWidth(this.selectedActionType === action.type ? 0 : 1)
      .borderColor('#D0D5DD')
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.selectedActionType = action.type;
        if (!this.isDoubleTapSelected()) {
          this.strictSecondTap = false;
        }
      })
  }

  build() {
    Scroll() {
      Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([$r('app.color.text_primary')])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          router.back();
        })
        Text($r('app.string.collection_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 8 })
      }
      .width('86%')
      .margin({ top: 56, bottom: 8 })

      Text($r('app.string.collection_subtitle'))
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 24 })

      TextInput({ placeholder: $r('app.string.collector_id_hint'), text: this.collectorId })
        .width('86%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .caretColor($r('app.color.primary_color'))
        .backgroundColor(Color.White)
        .borderRadius(12)
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.collectorId = value.trim();
        })

      Column({ space: 10 }) {
        Text($r('app.string.positive_scenario'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(POSITIVE_ACTION_OPTIONS, (action: ActionConfig) => {
            this.ActionChip(action)
          }, (action: ActionConfig) => action.type)
        }
        .width('100%')

        if (this.isDoubleTapSelected()) {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text('Strict second-tap timing')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('First tap before 2 s; second tap when the ring turns green (2–3 s).')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.strictSecondTap })
              .onChange((isOn: boolean) => {
                this.strictSecondTap = isOn;
              })
          }
          .width('100%')
          .margin({ top: 8 })
        }
      }
      .width('86%')
      .padding(14)
      .backgroundColor('#E8F8EF')
      .borderRadius(12)
      .margin({ top: 20 })

      Column({ space: 10 }) {
        Text($r('app.string.negative_scenario'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(NEGATIVE_ACTION_OPTIONS, (action: ActionConfig) => {
            this.ActionChip(action)
          }, (action: ActionConfig) => action.type)
        }
        .width('100%')
      }
      .width('86%')
      .padding(14)
      .backgroundColor('#FEF3F2')
      .borderRadius(12)
      .margin({ top: 12 })

      Column({ space: 6 }) {
        Text($r('app.string.collection_note_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text($r('app.string.collection_note_1'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        Text($r('app.string.collection_note_2'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('86%')
      .padding(14)
      .backgroundColor(Color.White)
      .borderRadius(12)
      .margin({ top: 12 })

        Button($r('app.string.sensor_diagnostic'))
          .width('86%')
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.primary_color'))
          .backgroundColor(Color.White)
          .borderRadius(21)
          .borderWidth(1)
          .borderColor($r('app.color.primary_color'))
          .margin({ top: 24, bottom: 10 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/DiagnosticPage' });
          })

        Button($r('app.string.start_collection'))
          .width('86%')
          .height(50)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.primary_color'))
          .borderRadius(25)
          .enabled(this.canStartCollection())
          .opacity(this.canStartCollection() ? 1 : 0.45)
          .margin({ bottom: 40 })
          .onClick(() => {
            this.startCollection();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollBar(BarState.Auto)
  }
}

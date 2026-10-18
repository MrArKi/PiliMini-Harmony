/** Nara LevelCanvas几何图标，11vp；SVG注明上游来源。 */
@Component
export struct MemberLevel {
  @Prop level: number = 0;
  private icon(): Resource {
    switch (this.level) {
      case 0: return $r('app.media.member_level_0');
      case 1: return $r('app.media.member_level_1');
      case 2: return $r('app.media.member_level_2');
      case 3: return $r('app.media.member_level_3');
      case 4: return $r('app.media.member_level_4');
      case 5: return $r('app.media.member_level_5');
      default: return $r('app.media.member_level_6');
    }
  }
  build() { Image(this.icon()).width(930 * 11 / 466).height(11).accessibilityText(this.level.toString() + '级') }
}

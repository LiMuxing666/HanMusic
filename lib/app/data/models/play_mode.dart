enum PlayMode {
  sequential,
  repeatAll,
  repeatOne,
  shuffle;

  String get label => switch (this) {
    sequential => '顺序播放',
    repeatAll => '列表循环',
    repeatOne => '单曲循环',
    shuffle => '随机播放',
  };
}

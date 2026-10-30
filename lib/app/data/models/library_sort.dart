enum LibrarySort {
  importOrder('导入顺序'),
  title('歌曲名称'),
  artist('歌手'),
  album('专辑');

  const LibrarySort(this.label);

  final String label;
}

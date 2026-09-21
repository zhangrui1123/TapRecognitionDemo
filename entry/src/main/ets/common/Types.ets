/**
 * 共享数据结构（被帖子页等组件复用）
 */

// 轮播图项
export interface ImageItem {
  src: Resource;  // 真实图片资源
  label: string;  // 地点名
  cap: string;    // 角标说明
}

// 行程小节
export interface DaySection {
  h: string;  // 小标题
  b: string;  // 正文
}

/**
 * 预演模板目录。只放展示用元数据，不引用 three 或场景工厂，
 * 这样模板选择弹窗可以留在画布首屏，3D 运行时仍按需加载。
 */

export type PrevisTemplateId = "empty" | "monologue" | "dialogue" | "blocking" | "product";

export type PrevisTemplate = {
    id: PrevisTemplateId;
    name: string;
    description: string;
    /** 列表里给用户的预期提示，不参与生成。 */
    summary: string;
};

/** 展示顺序即用户看到的顺序：空场景在最前，其余按上手复杂度递增。 */
export const PREVIS_TEMPLATES: PrevisTemplate[] = [
    { id: "empty", name: "空场景", description: "只有摄影机和三点布光，没有任何演员或道具。", summary: "摄影机 + 布光" },
    { id: "monologue", name: "单人对白", description: "一名演员居中，中近景机位，适合独白与特写。", summary: "1 演员 · 中近景" },
    { id: "dialogue", name: "双人对话", description: "两名演员面对面分立左右，过肩机位起手。", summary: "2 演员 · 对话机位" },
    { id: "blocking", name: "人物走位", description: "三名演员分散站位，广角机位便于安排走动路线。", summary: "3 演员 · 广角" },
    { id: "product", name: "产品/道具镜头", description: "产品置于中心，背景板与侧面道具就位，长焦特写。", summary: "产品 + 背景板 · 长焦" },
];

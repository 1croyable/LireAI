# API 候选

| 服务商 | 额度与模型选择 | 适用考虑 | 官方来源 |
| --- | --- | --- | --- |
| Gemini | 有免费输入/输出额度，但免费层仅开放部分模型；各模型有独立限额 | 先测试账户可用的 Pro/Flash 文本模型 | https://ai.google.dev/gemini-api/docs/pricing |
| DeepSeek | 按 token 付费；当前 Pro 的输入缓存未命中/输出每百万 token 为 $0.66/$1.98（非高峰），$1.32/$3.96（高峰） | 小额付费比较推理和语法表现 | https://api-docs.deepseek.com/quick_start/pricing/ |
| Groq | 免费计划开放包括 openai/gpt-oss-120b 的模型；该模型表中限额为 30 RPM、1000 RPD、8000 TPM、200000 TPD | 免费尝试更大的开放模型，但长对话可能遇到 TPM 限制 | https://console.groq.com/docs/rate-limits |
| OpenRouter | 汇聚多家服务和免费模型；Free 计划当前标示 50 次/天 | 一个 Key 比较不同厂商；具体免费模型目录随时间变化 | https://openrouter.ai/pricing/ |
| Grok（xAI） | 按 token 计费；当前旗舰页面列 Grok 4.6 输入 $2/百万、输出 $6/百万 | 可作为付费候选；与 Groq 不同 | https://docs.x.ai/developers/models |
| OpenAI | 主要文本模型按 token 计费；不能把 Free 使用层级的月使用上限理解为赠送余额 | 作为付费质量对照；以模型、地区和账户权限为准 | https://developers.openai.com/api/docs/pricing 、https://developers.openai.com/api/docs/guides/rate-limits |
| Mistral | Studio 有免费模式及速率/使用限制，可选模型权限按账户计划；本项目允许改选可用模型 | 不必更换 Key 即可测试更大的模型 | https://docs.mistral.ai/getting-started/quickstarts/studio/test-model-playground |

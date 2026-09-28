/**
 * Stash 脚本：拦截 TikHub 请求转接至 api.51web.eu.org 接口
 */

(async () => {
  const requestUrl = $request.url;

  // 1. 从插件发起的 TikHub URL 参数中解析 aweme_id / item_id / url
  const urlSearchParams = new URLSearchParams(requestUrl.split('?')[1] || '');
  const videoParam = urlSearchParams.get('aweme_id') || 
                     urlSearchParams.get('item_id') || 
                     urlSearchParams.get('url') || 
                     urlSearchParams.get('share_url');

  if (!videoParam) {
    // 若没有提取到有效视频参数，直接不做拦截放行
    $done({});
    return;
  }

  // 2. 构造你的解析网站接口 URL
  const myTargetUrl = `https://api.51web.eu.org/api/parse?token=w5_G03Gd6hSXSs4UF85YWdnIO1c&pid=5&url==${encodeURIComponent(videoParam)}`;

  try {
    // 3. 在本地向你的服务器发起 GET 请求
    const response = await $httpClient.get({ url: myTargetUrl });
    const myData = JSON.parse(response.body);

    // 4. 提取播放量等数据（根据你的 api.51web.eu.org 实际返回结构做下适配）
    const playCount = myData.play_count || myData.data?.play_count || myData.statistics?.play_count || 0;
    const diggCount = myData.digg_count || myData.data?.digg_count || myData.statistics?.digg_count || 0;
    const commentCount = myData.comment_count || myData.data?.comment_count || myData.statistics?.comment_count || 0;

    // 5. 将你的接口数据组装为 TikHub 插件能识别的标准 JSON Schema
    const mockTikHubData = {
      code: 200,
      msg: "success",
      data: {
        aweme_detail: {
          aweme_id: videoParam,
          statistics: {
            play_count: Number(playCount),     // 关键：抖音播放量
            digg_count: Number(diggCount),     // 点赞量
            comment_count: Number(commentCount)// 评论量
          }
        }
      }
    };

    // 6. 将构造好的响应体直接返回给 iOS 上的插件
    $done({
      response: {
        status: 200,
        headers: { "Content-Type": "application/json; charset=utf-8" },
        body: JSON.stringify(mockTikHubData)
      }
    });

  } catch (err) {
    console.log("Stash 请求 api.51web.eu.org 失败: " + err);
    $done({
      response: {
        status: 500,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: 500, msg: "Failed to query 51web API" })
      }
    });
  }
})();

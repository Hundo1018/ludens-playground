# Ludens Frontier:三層細化的實作計畫

這份文件是展示範例的工作計畫,分三層:第一層寫目標與決策,第二層寫每階段的工作清單,第三層寫可逐步照做的指令。執行者讀到自己需要的那一層為止。完成一步就更新「現況」。

## Context

使用者要一個展現七類特色(Rendering、Physics、Animation、AI、Streaming、Networking、Optimization)的範例。已定案:一個串流大世界;Nanite / GI / 光追做網頁可行的等價物並以實際名稱標示;網路用頁面內模擬伺服器;分階段上線;可以用多個 wasm。

2026-11-13 使用者要求把計畫細化成三層,讓能力遞減的模型也能照做:第一層給 Opus,第二層給 Sonnet,第三層給 Haiku。本檔即這三層。三層描述同一件工作,越後面越具體;執行者讀到自己那一層為止,需要時往下一層查細節。

### 現況(2026-11-13)

- 已合併:PR #53 虛擬搖桿套件;PR #54 多 wasm 探針(`app/zone_main.mojo`、`shell/web/zone_worker.ts`、`scripts/multi_wasm_probe.py`)。探針量到:Worker 內 wasm64 可載入、雜湊與原生相同、該場景每 tick 約 12 ms、每實例記憶體 38 MiB。
- PR #55(階段 1 的主體):`game/frontier.mojo`、`game/frontier_hud.mojo`、`tests/frontier.mojo`(26 項)、`scripts/frontier_check.mjs`(31 項,已接進 `build-pages --check`)。
- T0 已完成:wgpu-mojo#30 已合併(`e781b8b`),網頁上可用 `wgpuDeviceCreateSampler`、`wgpuSamplerRelease`、`wgpuQueueWriteTexture`;`deps.lock` 已指到這個版本。T1(素材管線)與 T2(貼圖渲染)可以開始。
- 階段 3b(大量群眾)已規劃,第一步是量測探針 3b-0。
- 階段 1 還沒做的:S1-5(原生對 wasm 的雜湊)、S1-6(觸控配置)。這兩步可以直接照第三層做。
- 之前記錄的「擷取失敗」已解決,原因在檢查腳本而不在遊戲,見「已知陷阱」表最後一列。

### 使用者的決定

| 日期 | 決定 |
|---|---|
| 2026-11-13 | 一個串流大世界;Nanite / GI / 光追做網頁可行的等價物並以實際名稱標示;網路用頁面內模擬伺服器;分階段上線 |
| 2026-11-13 | 可以用多個 wasm |
| 2026-11-13 | 畫面不要太素;貼圖用免費素材,不自己畫 |
| 2026-11-13 | 前置作業完成後先停,後續可能交給較低階的模型 |
| 2026-11-13 | 城鎮的 24 名群眾不足以顯示 ECS 的效能;要有一個大量實體的場面(階段 3b) |
| 2026-11-13 | T0(wgpu-mojo 網頁貼圖支援)由強模型先做 |

### 兩個 checkout 的對應(每次開工先確認)

| 本機目錄 | GitHub repo | 內容 |
|---|---|---|
| `/home/user/ludens-shell` | `Hundo1018/ludens-engine` | app、game、shell/web、scripts(本計畫主要在這裡) |
| `/home/user/ludens-engine` | `Hundo1018/ludens-core` | 模擬核心 |

工作階段重啟會把 remote 改回舊名。push 前一律 `git remote set-url origin https://github.com/Hundo1018/<repo>` 再 `git remote get-url origin` 確認。

---

# 第一層(給 Opus):目標、決策、驗收

每階段一個 PR,CI 全綠後以 `merge` 合併,合併後確認 Pages 的 `build.txt` 是新 commit。每個 PR 說明附量到的數字與未驗證項目。

| 階段 | 交付 | 關鍵決策 | 驗收(全部要有可重跑的檢查) |
|---|---|---|---|
| 1 世界骨架 | `?frontier`:512 m 地圖、`WorldPartition` 串流、玩家與鏡頭、視錐剔除、HUD 數字 | 物體一律以 `BodySpec` 註冊;地面是一塊常駐靜態方塊;串流以 tick 計數驅動以保確定性 | 無視窗測試;`frontier_check` 連過 3 次;`game-parity` 加入 frontier 雜湊 |
| T 貼圖 | 免費 CC0 貼圖、triplanar 貼圖取樣、逐像素光照、天空與霧 | 貼圖來源只用 CC0;下載清單與雜湊進版控,圖檔在建置時下載並轉成固定大小;方塊與球沒有 UV,所以用世界座標的 triplanar 取樣 | 原生與網頁都畫出貼圖;每張圖的來源與授權列在 `assets/CREDITS.md`;像素檢查確認畫面不是單色 |
| 2 物理區 | 採石場:可破壞牆 + 關節機具;營地:布料旗、軟體、繩索 | 每區是一個 `Zone` 模組,先在主 wasm 內跑,量到超過預算再搬進 Worker;`EmbedWorld` 只允許一個破壞物體,所以牆只有一面 | 牆被撞後碎片數增加;旗的頂點位移;繩長守恆;離區後該區停止 tick |
| 3 AI 區 | 城鎮:navmesh、ORCA 群眾、行為樹居民、感知 | navmesh 在進區時烘一次並快取;群眾數量由預算決定 | 到達率、最小間距不小於 0;行為樹狀態轉換;預設頁面切到 frontier |
| 3b 大遷徙(ECS) | 城鎮外的平原上 2 萬到 10 萬個以 `ecs.World` 管理的行人,HUD 顯示每個 system 的耗時,可即時切換儲存後端與 OOP 基準 | 數量由量測決定,不預先承諾;導航用預先取樣的流場格,不用逐人尋路;只有最近的幾十人用 ORCA 與行為樹;放在自己的 wasm Worker | 同輸入下各後端與 OOP 基準的位置雜湊相同;每個 system 的 ns/實體有原生與 wasm 的數字;HUD 的數字與量測一致 |
| 4 動畫區 | 訓練場:程式產生的骨架與動作、motion matching、腳步 IK、混合 | 無 skinning 管線前,骨頭以方塊繪製;skinning 留到渲染階段 | 特徵查詢命中預期片段;腳踝離地誤差上限;混合權重連續 |
| 5 網路區 | 靶場:`server.wasm`(Worker)權威伺服器、主模組兩個客戶端、`SimLink` 可調 | 封包格式即 `NetPeer.outgoing/receive` 的位元組;UI 滑桿調延遲、抖動、掉包 | 150 ms 延遲下預測客戶端誤差上限;延遲補償命中而未補償未命中;雜湊收斂 |
| 6 渲染 A | 3 級 LOD、shadow map、半球環境光、每格探針 | 先補 wgpu-mojo 網頁轉譯層(跨 repo PR),再用 | 各級三角形數;陰影像素檢查;原生與網頁像素差在容忍內 |
| 7 渲染 B | compute BVH 的 AO 與一次反射 | 效能不足則只開 AO;以「軟體光追」標示 | 與 CPU `BVH.raycast` 逐光線比對命中 |

共同原則:
- 不稱 Nanite / GI / 硬體光追;HUD 與 README 用實際名稱。
- 預算:主執行緒目標以量測為準;超過時先降級(`SimBudget`、`BudgetTiers`),再考慮搬進 Worker。
- 每個可替換的做法(主 wasm 內 vs Worker)都要有同輸入同雜湊的檢查。
- 我無法驗證真實 GPU 與手機;每階段上線後請使用者試玩並回報。

---

# 第二層(給 Sonnet):每階段的工作清單

通用:每個新模組配一個 `tests/<name>.mojo`(加入 `pixi.toml` 的 `test-game`);每個新匯出函式寫在 `app/main.mojo` 並跑 `scripts/gen_exports.py`;每個瀏覽器行為配一個 `scripts/*_check.mjs` 並接進 `scripts/build_pages.py` 的 `check()`。

## 階段 1(收尾)

主體已在 PR #55。剩下:

1. `scripts/game_parity.py` 增加 frontier:固定輸入 600 幀,比對原生與 wasm 的 `app_frontier_hash`。
2. 觸控:`FRONTIER_PAD`(搖桿、Jump、R),`touch_check.mjs` 參數化後對 `?frontier` 再跑一次。
3. HUD 的各子系統耗時(目前只有整幀的 CPU 時間)。

## 階段 T 貼圖(排在階段 1 之後、階段 2 之前)

分三段。T0 已完成(2026-11-13);T1 可照第三層做;T2 的步驟要由第二層以上的模型依下面的介面補寫。

**T0 wgpu-mojo 網頁轉譯層(另一個 repo:`Hundo1018/wgpu-mojo`)— 已完成,以下留作紀錄**

結果:只缺三個函式,已補上並有瀏覽器測試(`examples/web/texture_web.mojo`:2 層、2 級 mip 的陣列貼圖,重複取樣)。bind group 的 sampler / texture entry、陣列貼圖、`2d-array` view 原本就可用。T2 可直接照該範例的寫法:`device.create_texture(w, h, layers, RGBA8Unorm, TEXTURE_BINDING | COPY_DST, 2, mips, 1, label)`、每層每級一次 `device.queue_write_texture(tex, mip, WGPUOrigin3D(0, 0, layer), WGPUTextureAspect.All, bytes, bytes_per_row, rows, w, h, 1)`、`WGPUTextureViewDescriptor(..., WGPUTextureViewDimension.D2Array, ...)`、`device.create_sampler(Repeat, Repeat, Repeat, Linear, Linear, Linear)`。注意 `create_sampler` 的預設濾波是 Nearest,要線性過濾必須明確傳 `WGPUFilterMode.Linear`(值 2)。尚未在網頁上測過的:比較取樣、各向異性大於 1、`CopyBufferToTexture`(仍會 trap)。

原始工作項目:

現況(已查):`web/implemented.txt` 列出的 63 個函式中沒有 `wgpuDeviceCreateSampler` 與 `wgpuQueueWriteTexture`;沒列的函式在網頁上會 trap。

- 在 `web/webgpu_impl.mjs` 實作 `wgpuDeviceCreateSampler`、`wgpuSamplerRelease`、`wgpuQueueWriteTexture`,並加進 `web/implemented.txt`。
- 確認 `wgpuDeviceCreateBindGroupLayout` / `wgpuDeviceCreateBindGroup` 的網頁實作能處理 `sampler` 與 `texture` 兩種 entry(目前只確定 buffer 可用);`wgpuDeviceCreateTexture` 能建 `depthOrArrayLayers > 1` 的貼圖、`wgpuTextureCreateView` 能建 `2d-array` 的 view。
- 每項加一個網頁測試(該 repo 的 `web/test.html` 流程)與原生測試;在 ludens-engine 更新 `deps.lock` 的 wgpu-mojo 版本。

**T1 素材管線**

- 來源(2026-11-13 從本環境實測可連線):ambientCG(`https://ambientcg.com`,CC0)、Poly Haven(`https://polyhaven.com`,CC0;檔案在 `https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_diff_1k.jpg`)。Kenney 從本環境連線得到 403,不使用。
- `assets/manifest.toml`(進版控):每列 `name`、`url`、`sha256`、`license = "CC0-1.0"`、`source_page`。
- `scripts/fetch_assets.py`:讀清單,下載到 `build/assets/src/`(不進版控),驗證 sha256,用 Pillow 縮成 256×256 RGBA(本環境已有 Pillow 13.0.0),產生含 mip 的 `build/web/textures.bin`(檔頭:張數、邊長、mip 數;之後依序是每張圖每級的 RGBA 位元組)。
- `assets/CREDITS.md`(進版控):每張圖的名稱、作者或網站、網址、授權。
- 第一批 8 張:草地、泥土、岩石、石磚、混凝土、木板、金屬板、布料。每區地面與該區物件各用一張。
- 網站多 8 × (256² × 4 × 4/3) ≈ 2.8 MB 的下載;頁面以 `fetch` 取得後經新匯出 `app_textures(ptr, len)` 交給 wasm。這同時是「資產串流」的第一個實例。

**T2 渲染器**

- `app/render3d.mojo` 增加(或另寫 `app/render_scene.mojo`):一張 8 層的 2D array 貼圖 + 一個 sampler;實例資料多一個材質編號。
- fragment shader:以世界座標做 triplanar 取樣(三個軸向各取一次,用法線的絕對值加權),再乘上實例顏色;光照改成逐像素(方向光 + 半球環境光);距離霧與天空漸層。
- 貼圖還沒到(下載中或失敗)時用 1×1 的白色貼圖,畫面退回單色,不能卡住。
- 檢查:`frontier_check.mjs` 加一項:地面區域內相鄰取樣點的顏色變異數大於門檻(單色時為 0)。

## 階段 2 物理區

新檔 `game/zone.mojo`:

```mojo
trait Zone(Movable):
    def enter(mut self, mut world: EmbedWorld) raises      # 玩家進入範圍:建立本區內容
    def leave(mut self, mut world: EmbedWorld) raises      # 離開:移除本區加入的物體
    def tick(mut self, mut world: EmbedWorld, player: Vec3, dt: Real) raises
    def draw(self, mut out: List[DrawItem]) raises
    def count(self) -> Int                                 # HUD 用:本區模擬元素數
    def hash(self) -> UInt64
```

`Frontier` 持有各區實例,依 `zone()` 的變化呼叫 `enter` / `leave`,只 tick 目前所在的區。

- `game/zone_quarry.mojo`:`world.add_fracture_box(pos, half, pieces, seed, stress, density)` 一面牆;碎片以 `world.fracture.fragments()` 與 `world.state(world.fragment_handle(i))` 繪製;一台以 `add_hinge_joint` 連接的擺錘撞牆;按鍵(Jump 在區內近距離)釋放擺錘。
- `game/zone_camp.mojo`:
  - 旗:`grid_mesh(nx, nz, sx, sz, origin)` → `MeshCloth(verts, tris, density, 0, bend)`,`pin` 旗桿側兩角,`step(world.scene, DT, G)`,`wind` 欄位設風;以每個頂點一個小方塊或每個三角形一個薄方塊繪製(階段 6 改成網格)。
  - 軟體:`world.scene.add_soft(SoftBody.box_lattice(center, half, 4, mass, 1e-4))`,需要 `scene.step_soft`;確認 `EmbedWorld.physics_tick` 是否呼叫 `step_soft`,若否則本區自行管理一個獨立的 `ContactScene6` 給軟體。
  - 繩:`Rope(a, b, 24, mass, 0, 0, length)`,`pin(0, a)`,另一端 `attach` 到一個動態箱;`step(world.scene, DT, G)`。
- 測試 `tests/frontier_quarry.mojo`、`tests/frontier_camp.mojo`:見第三層的斷言清單。
- HUD 增加一行 `SIM <區名> <count>`。
- 量測:各區 `tick` 的 ms(原生與 wasm),寫進 PR。超過 8 ms 的區在本階段就搬進 Worker(沿用 `zone_worker.ts` 協定,`app/zone_main.mojo` 增加區種類參數)。

## 階段 3 AI 區

- `game/zone_town.mojo`:
  - `enter`:由本區建築的 `BodySpec` 產生三角形(地面四邊形扣掉建築佔地,沿用 `game/arena.mojo` 的 `_nav_box` / `_tri` 寫法)→ `bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 32))`。
  - 群眾:`Crowd[Orca](Orca(), CrowdParams.default())`,`add_agent(mesh, p, 0.3, 1.4)` × N,`set_target` 指向輪替的目的地,`step(mesh, DT)`;到達後換目的地。
  - 守衛 2 名:`BehaviorTree`(reactive selector:看見玩家→追;否則巡邏),`Perception` 的 `sight_candidates` + `world.raycast` + `commit_sight`;結構照 `game/arena.mojo` 的 `ChaserHost`。
  - N 由 `BudgetTiers` 或簡單規則決定:量到的 tick ms 超過目標就減少啟用的 agent。
- 測試 `tests/frontier_town.mojo`。
- 把頁面預設改成 frontier(`shell/web/app.ts` 的模式選擇;`?arena` 保留舊遊戲);同步改 `game_screenshot.mjs` / `touch_check.mjs` 的網址為 `?arena`。

## 階段 3b 大遷徙:用大量實體顯示 ECS 的效能

**為什麼城鎮的群眾不夠**(`BENCHMARK_REPORT.md` 的實測,原生):

| 做法 | 規模 | 每實體每 tick |
|---|---:|---:|
| `Crowd[Orca]` | 64 人 | 270 ns |
| `Crowd[Orca]` | 1024 人 | 1173 ns(整步 1.2 ms,且隨人數超線性成長) |
| ECS archetype `for_each2`(位置 += 速度) | 4000 個 | 0.72 ns |
| ECS archetype SIMD 積分 | 4000 個 | 0.18 ns |
| OOP 基準,同一個精簡更新 | 4000 個 | 0.83 ns |
| OOP 基準,物件帶約 2 KB 冷資料、只讀位置 | 4000 個 | 3.91 ns(ECS SoA 為 0.82 ns) |

從這張表得到兩個設計結論:
1. ORCA 的成本是每人 0.3 到 1.2 µs,24 人或 1024 人都只是在量 ORCA,不是在量 ECS。要顯示 ECS,實體數要到數萬,而且每個 system 只碰少數欄位。
2. 在「每個實體都更新、資料很精簡」的工作上,OOP 基準與 ECS 一樣快(0.83 對 0.76 ns)。ECS 的優勢出現在實體帶有大量用不到的資料、system 只讀其中幾欄,以及能用 SIMD 的欄位運算。所以示範的實體必須帶有真實份量的冷資料(名字、背包、狀態),比較才誠實;HUD 上兩種情況都要能切換來看。

**設計**

- 位置:城鎮與樞紐之間的平原(x 48 到 96、z 48 到 160 一帶),一大群行人在數個集結點之間遷徙。
- 元件(`ecs` 的 `ComponentType`):`Pos`(x, z)、`Vel`(x, z)、`Goal`(集結點編號、到達計數)、`Look`(顏色、大小)、`Cold`(約 200 bytes 的填充資料,代表 system 不碰的狀態)。
- Systems,每個都用 `World.for_each2` / `for_each3`:
  1. `steer`:讀 `Pos`、`Goal`,寫 `Vel`。方向取自預先取樣的流場格:進區時對每個集結點呼叫一次 `FlowField.build(mesh, goal)`,再把 `FlowField.direction(mesh, p)` 取樣成 1 m 一格的二維陣列,之後每個實體只做一次陣列查表。
  2. `separate`:用均勻格計數做密度排斥(每格人數超過門檻就沿密度梯度推開)。不用 ORCA。
  3. `integrate`:`Pos += Vel * dt`。
  4. `arrive`:到集結點就換下一個。
  5. `pack`:把視錐內的實體寫進繪製陣列。
- 分層(顯示排程與預算):距玩家 30 m 內最多 64 人交給 `Crowd[Orca]` 與行為樹(就是階段 3 的城鎮居民那套);30 到 150 m 每 tick 跑全部 system;更遠的每 4 tick 跑一次。層的分界由 `BudgetTiers` 依量到的時間調整。
- 可切換的實作(HUD 按鍵或頁面按鈕):`archetype for_each`、`sparse for_each`、`handle 迴圈(query + get/set)`、`oop` 套件的基準。四者跑同一份輸入,HUD 顯示各 system 的 ms 與每實體 ns。這是一個 seam,要有 parity 測試:同輸入 600 tick 後四者的位置雜湊相同。
- 執行位置:自己的 `sim.wasm` Worker(沿用 `zone_worker.ts` 的協定,`app/zone_main.mojo` 增加區種類),每 tick 以可轉移的 `Float32Array` 送回視錐內的位置。主執行緒不付模擬成本。
- 繪製:現有渲染器每個實例畫 1152 個頂點、上限 2048 個實例,不能用來畫數萬人。新增一條「群眾 pass」:每人一個 36 頂點的方塊(之後換成低面數人形),實例資料只有位置、朝向、顏色、大小;依距離剔除與 LOD(遠處每人一個 6 頂點的面片)。這等於把階段 6 的 LOD 工作提前一部分。

**先量再定數量(第一步,不可省略)**

寫 `app/crowd_probe.mojo` 與 `scripts/crowd_probe.py`(仿 `app/bench.mojo` 與 `scripts/bench.py`):N = 1e4、5e4、1e5,量每個 system 的 ns/實體,原生與 wasm 各一份,四種實作各一份。然後用下面的規則定 N,並把表格寫進 PR:

- Worker 內整個 tick 不超過 8 ms(留一半給 60 Hz 的排程抖動)→ N 的上限。
- 繪製:視錐內實例數 × 頂點數在 SwiftShader 上不超過檢查的時限;真實 GPU 的上限我無法量,預設值取保守的一半,並提供網址參數 `?crowd=<N>` 讓使用者在自己的機器上調。

**測試** `tests/frontier_migration.mojo`:實體數不變;600 tick 後所有座標有限且在平原範圍內;至少 30 % 的實體到達過一次集結點;四種實作雜湊相同;關掉分層與開著分層時「30 到 150 m」那一層的結果相同。瀏覽器:`scripts/migration_check.mjs` 讀 `window.shell.migration`(實體數、各 system ms、目前實作),切換實作後數字改變而實體數不變。

## 階段 4 動畫區

- `game/mocap.mojo`:以程式產生一副 12 根骨頭的人形(`Skeleton(parent, rest)`)與 4 個 `AnimClip`(idle、walk、run、turn),`set_key` 用正弦擺動。
- `game/zone_training.mojo`:
  - 一名假人沿路徑走:`MotionDB.add_clip` 建庫;每 6 tick 以目前速度與腳位置組特徵 `MotionDB.feature`,`query` 得到片段與時間,切換時用 `blend` 過渡 0.2 s。
  - 第二名假人用 `AnimGraph`(idle↔walk,由 `floats[speed]` 驅動)做對照。
  - 腳:`to_world` 取腳踝,`foot_plant(ankle, 0.08, ground_y, normal, 0.3, 0.5)`,再 `two_bone(hip, knee, ankle, target, pole)`;地面高度取訓練場的平台(`world.raycast` 向下)。
  - 頭:`look_at(forward, to_player, 1.0)`。
  - 繪製:每根骨頭一個細長方塊(兩端世界座標算位置、長度、朝向)。
- 測試 `tests/frontier_training.mojo`。

## 階段 5 網路區

- `game/range_sim.mojo`:`struct RangeSim(NetSim)`,內容參照 `ArenaSim`(玩家可移動、幾個靶),實作 `players/tick/step/save/load/hash`。
- `app/server_main.mojo`(第二個 wasm 入口,仿 `app/zone_main.mojo`):匯出 `app_server_create(players)`、`app_server_receive(ptr, len, from)`、`app_server_update(target_tick)`、`app_server_outgoing(to) -> ptr/len`、`app_server_hash()`;內部是 `SnapshotServer[RangeSim]`。
- `shell/web/server_worker.ts`:訊息 `{type:"start"}`、`{type:"packet", from, bytes}`、`{type:"tick", target}` → 回 `{type:"packet", to, bytes}`、`{type:"state", tick, hash}`。
- `game/zone_range.mojo`(主模組):兩個 `SnapshotClient[RangeSim]`(一個由玩家輸入驅動並做預測,一個只做插值顯示);上下行各經一個 `SimLink(latency, jitter, loss, seed)`;`PoseRing.record` 每 tick 記錄;射擊時送出帶 tick 的輸入,伺服器端 `rewind_ray_cast` 判定。
- 主模組新匯出:`app_range_outgoing`、`app_range_receive`、`app_range_set_link(latency, jitter, loss)`、`app_range_stat(which)`。
- 頁面:HUD 旁三個滑桿(DOM,仿 `vpad_view.ts` 的做法);畫面上以三種顏色畫伺服器真值、預測、無預測。
- 測試:`tests/frontier_range.mojo`(單行程內直接連 `SnapshotServer` 與 client,不經 Worker)+ `scripts/range_check.mjs`(瀏覽器經 Worker)。

## 階段 6 渲染 A

- wgpu-mojo(另一個 repo,開 issue + PR):在 `web/implemented.txt` 與轉譯層補 `CreateSampler`、比較取樣、`QueueWriteTexture`;每項配 `tests/` 的網頁測試;ludens-engine 更新 `deps.lock`。
- `app/render_scene.mojo`(新渲染器,不動 `app/render.mojo`):
  - 網格表:box、sphere(3 級:16×12、8×6、4×3)、之後的布料網格;頂點與索引緩衝取代 vertex pulling。
  - LOD:`radius / distance * 螢幕高 / tan(fov/2)` 的像素大小選級;HUD 顯示各級實例數與三角形數。
  - Shadow map:方向光正交投影覆蓋玩家周圍 80 m,2048² 深度貼圖,PCF 3×3。
  - 環境光:半球(天空色、地面色依法線混合)+ 每格一個 L1 球諧探針,進格時以 `world.scene.ray_cast_batch` 射 64 條光線估計遮蔽後存入。
- 像素 parity:新增 frontier 的原生對網頁比較,容忍值另列。

## 階段 7 渲染 B

- 以 `BVH[3].build_boxes(boxes, proxies, sah=True)` 建目前載入物體的 BVH;把 `nodes`(`box.min`、`box.max` 各 4 個 f32、`left`、`right`、`proxy`)攤平成 storage buffer。
- compute pass:半解析度,從深度重建位置,每像素 4 條 AO 光線 + 1 條反射光線,堆疊式走訪;結果以雙邊濾波放大後合成。
- 驗證:同一批光線在 CPU 用 `BVH.raycast` 算一次,逐條比對命中與否與 `t`(容忍 1e-3)。
- 量測 SwiftShader 與原生的 ms;超過預算則預設只開 AO,反射以 `?rt=full` 開啟。

---

# 第三層(給 Haiku):逐步指令

## 通用規則(每一步都適用)

1. 只在指定的目錄下工作。指令一律從 `/home/user/ludens-shell` 執行,除非步驟寫了別的目錄。
2. 建置與測試一律用下表的指令,不要自己發明指令:

| 目的 | 指令 | 成功時最後一行長這樣 |
|---|---|---|
| 無視窗測試(單一) | `pixi run -e wasm python3 scripts/test_native.py <name>` | `<name>: N / N checks` |
| 全部遊戲測試 | `pixi run -e wasm test-game` | 每個測試各一行 `N / N checks` |
| 建 wasm | `pixi run -e wasm build-wasm` | `build_wasm: build/app.wasm (... audits ok)` |
| 建網頁 | `pixi run -e wasm build-web` | `build_web: ... (N files)` |
| 產生匯出宣告 | `python3 scripts/gen_exports.py` | 無錯誤 |
| 目錄規則 | `pixi run -e wasm check-layout` | `layout: PASS (0 problems)` |
| 站台 + 瀏覽器檢查 | `pixi run -e wasm build-pages --check` | `game-shot: PASS`、`touch-check: PASS`、之後加入的檢查各一行 PASS |
| 多 wasm 探針 | `pixi run -e wasm multi-wasm-probe` | `multi-wasm-probe: PASS` |

3. 任何一行出現 `FAIL`、`error`、`Unhandled exception` 就停下來。不要改測試讓它通過;不要刪掉檢查;不要加 `--no-verify`。把失敗的那幾行原樣貼給使用者或上一層模型。
4. 瀏覽器檢查要連續通過 3 次才算通過(曾經發生過一次碰巧通過)。
5. 提交訊息格式:`type(scope): subject`,結尾兩行:
   ```
   Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_01DbhK6fvGCerakThMGANEsy
   ```
6. push 前執行並檢查輸出:
   ```
   git remote set-url origin https://github.com/Hundo1018/ludens-engine
   git remote get-url origin        # 必須印出 https://github.com/Hundo1018/ludens-engine
   ```
   只做一般的 `git push -u origin <branch>`;不要 force push。
7. PR:推送後用 `mcp__github__create_pull_request`(owner `Hundo1018`、repo `ludens-engine`、base `main`),內文結尾:
   ```
   🤖 Generated with [Claude Code](https://claude.com/claude-code)

   https://claude.ai/code/session_01DbhK6fvGCerakThMGANEsy
   ```
   然後 `mcp__claude-code-remote__subscribe_pr_activity`。CI 全綠才用 `mcp__github__merge_pull_request`(`merge_method: "merge"`)。
8. 合併後確認:`curl -sS https://hundo1018.github.io/ludens-engine/build.txt` 印出的雜湊等於合併 commit。

## Mojo 的已知陷阱(寫程式前先讀)

| 會出錯的寫法 | 正確寫法 |
|---|---|
| `0.5 if c else 0`(型別不明) | `Real(0.5) if c else Real(0)` |
| 函式命名為 `case` | 換名字,`case` 是保留字 |
| `len(some_string)` | `some_string.byte_length()` |
| 建構子用參數屬性、把函式存進結構體 | 用 trait + 空結構體 |
| 在 `mut self` 方法裡把 `self.x` 直接傳給另一個要 `mut self` 的呼叫 | 先複製到區域變數 |
| `match` 裡寫 `case NAME:` | `case == NAME:` 或用 `if/elif` |
| `Vec3(x, y, z)` | `Vec3(x, y, z, 0.0)`(四個分量) |
| 相機彈簧臂撞到玩家自己 | `self.arm.filter.mask = CAT_WORLD`,玩家 layer 設為別的類別 |
| `_draw_scene` 新分支沒有 `return` | 每個模式分支畫完就 `return` |
| 把玩家傳送到建築物內部 | 城鎮的街道在每格的 x0+16、z0+16;用 (112, 112) |
| 新 `.ts` 檔沒進 `scripts/build_web.py` 的清單 | 加進那個 tuple,否則網站載入時 404 |
| 需要原生靜態庫的腳本在乾淨機器失敗 | 先 `import native_libs; native_libs.build_all()` |
| 截圖檢查的顏色數門檻設在量測值附近 | 暫停畫面量到 49 到 52 種顏色,門檻 50 會碰運氣失敗。門檻要離兩邊的量測值都遠(現為 30;清空的畫面是 1) |
| 用 `/json/new?<網址>` 開分頁,而網址含 `&` | `&` 之後會被丟掉(頁面少了 `offscreen` 就會畫到 canvas,headless Chrome 隨即失去 GPU 裝置,症狀是 `Buffer map failed, status=3`)。先開 `about:blank`,再用 `Page.navigate` |
| 在 `?offscreen` 下讀 `drawn` / `culled` | 這兩個數字在畫一幀時才更新;先擷取一幀再讀 |

## 階段 1 的步驟

S1-1 到 S1-4 已完成(PR #55)。剩下 S1-5 與 S1-6。

**S1-5 原生對 wasm 的雜湊**

打開 `scripts/game_parity.py` 與 `scripts/game_node.mjs`,找到 arena 的做法(固定輸入跑 N 幀後比 `app_game_hash`)。照同樣的結構加一段:`app_set_mode(app, 2)`,每幀 `app_input` 送 W 鍵按下,跑 600 幀,讀 `app_frontier_hash`;原生端在 `tests/frontier.mojo` 尾端印出同樣輸入的 `hash()`。兩邊數字必須相同。執行 `pixi run -e wasm game-parity`。

**S1-6 觸控配置**

`shell/web/app.ts`:在 `ARENA_PAD` 下方加 `FRONTIER_PAD`(複製 `ARENA_PAD`,刪掉 `pause` 那個按鈕),`mountVirtualPad` 的第二個參數改成 `location.search.includes("frontier") ? FRONTIER_PAD : ARENA_PAD`。`shell/web/index.html` 的觸控說明不用改。跑 `pixi run -e wasm build-pages --check`。

**S1-7 README、PR、合併**

README 的「Frontier」一節已存在;把「Not in yet」那句裡已完成的項目刪掉。照規則 5 到 8 完成。

## 階段 T 的步驟

**T0** 已完成,不用做。

**T1-1 清單與下載腳本**

1. 建 `assets/manifest.toml`。每張圖一段,例:
   ```toml
   [[texture]]
   name = "rock"
   url = "https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_wall_10/rock_wall_10_diff_1k.jpg"
   source_page = "https://polyhaven.com/a/rock_wall_10"
   license = "CC0-1.0"
   sha256 = ""
   ```
   其餘 7 張到 `https://polyhaven.com/textures` 找,條件:授權頁寫 CC0;檔名規則同上(`<id>_diff_1k.jpg`)。找不到合適的就停下來問使用者,不要用授權不明的圖。
2. 寫 `scripts/fetch_assets.py`(Python,在 pixi 的 wasm 環境執行):對每段下載到 `build/assets/src/<name>.jpg`;算 sha256;清單裡 `sha256` 是空字串時印出算到的值並結束(讓人貼回清單);不相等時報錯結束;相等才繼續。
3. 用 Pillow:`Image.open(p).convert("RGBA").resize((256, 256), Image.LANCZOS)`,再依序縮成 128、64、…、1 做 mip。
4. 寫 `build/web/textures.bin`:三個 little-endian uint32(張數、256、mip 級數 9),接著每張圖從大到小每級的 RGBA 位元組。
5. 在 `pixi.toml` 加 `fetch-assets = "python3 scripts/fetch_assets.py"`;在 `scripts/build_pages.py` 的 `build()` 於複製檔案之前呼叫它。
6. 寫 `assets/CREDITS.md`:表格欄位為名稱、來源網站、網址、授權。
7. 驗證:`pixi run -e wasm fetch-assets` 最後一行印出 `fetch-assets: 8 textures, <位元組數> bytes`;`ls -l build/web/textures.bin` 的大小等於 `12 + 8 × 349524`(= 2,796,204)。

**T2** 的步驟在 T0 合併後由第二層以上的模型補寫(shader 與 bind group 的細節取決於 T0 實作出來的介面)。

## 階段 2 到 5:每個區域的步驟卡

每張卡的做法相同:(1) 建檔並貼上骨架;(2) 填入「呼叫」欄的程式;(3) 寫測試並加入 `pixi.toml` 的 `test-game`;(4) 在 `Frontier` 註冊;(5) 跑通用規則的指令;(6) PR。

**共用骨架**(每個區域檔案開頭):

```mojo
from embed.world import EmbedWorld, pack_body
from game.arena import DrawItem
from geometry.quat import Quat
from geometry.vec import Real, Vec3

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0.0, -9.81, 0.0, 0.0)
```

### 卡 2a 採石場 `game/zone_quarry.mojo`

| 項目 | 內容 |
|---|---|
| 位置 | 牆中心 `(112, 2, -112)`,half `(4, 2, 0.3)` |
| 建立 | `self.wall = world.add_fracture_box(Vec3(112.0, 2.0, -112.0, 0.0), Vec3(4.0, 2.0, 0.3, 0.0), 40, 7, 5e4, 2000.0)` |
| 擺錘 | 支點靜態箱在 `(112, 7, -106)`;錘 `world.add_box(Vec3(112.0, 3.0, -106.0, 0.0), Vec3(0.6, 0.6, 0.6, 0.0), 400.0, False)`;`world.add_distance_joint(pivot, ball, Vec3(0,0,0,0), Vec3(0,0,0,0), 4.0)` |
| 釋放 | 玩家距牆 12 m 內按 Jump:`world.set_velocity(ball, Vec3(0.0, 0.0, -9.0, 0.0), Vec3(0,0,0,0))` |
| 繪製 | `for i in range(world.fracture.fragments()): var s = world.state(world.fragment_handle(i))` → `DrawItem(0, s.pos, 四元數, Vec3(0.3, 0.3, 0.15, 0.0), 灰色)` |
| 限制 | 一個世界只能有一個破壞物體;存在時 `save()` / `load()` 會被拒絕。離區時不移除牆(不呼叫 `leave` 的移除) |
| 測試斷言 | 進區後 `fragments() == 0 或 >= 30`(依 API 實際行為記錄);釋放擺錘 180 tick 後 `len(world.frame_fracture)` 累計 > 0;至少 5 個碎片的 y 比初始低 0.5 m 以上;兩次執行雜湊相同 |

### 卡 2b 營地 `game/zone_camp.mojo`

| 項目 | 內容 |
|---|---|
| import | `from physics.cloth import MeshCloth, grid_mesh`、`from physics.rope import Rope`、`from physics.softbody import SoftBody` |
| 旗 | `var m = grid_mesh(12, 8, 3.0, 2.0, Vec3(-112.0, 5.0, -112.0, 0.0))`;`self.flag = MeshCloth(m[0], m[1], 0.3, 0, 1e-3)`;`self.flag.pin(0)`;`self.flag.pin(頂點數 - 13)`(旗桿側的另一角,用 `len(self.flag.x)` 算);每 tick `self.flag.step(world.scene, DT, G)` |
| 繩 | `self.rope = Rope(Vec3(-106.0, 6.0, -112.0, 0.0), Vec3(-106.0, 2.0, -112.0, 0.0), 24, 2.0, 0, 0, 4.0)`;`self.rope.pin(0, Vec3(-106.0, 6.0, -112.0, 0.0))`;每 tick `self.rope.step(world.scene, DT, G, 8, 4)` |
| 軟體 | 先確認:`grep -n "step_soft" build/deps/ludens-core/embed/world.mojo`。有結果 → `_ = world.scene.add_soft(SoftBody.box_lattice(Vec3(-118.0, 1.5, -112.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 4, 20.0, 1e-4))`。沒有結果 → 停下來回報,不要自己改引擎 |
| 繪製 | 旗:每個 `self.flag.x[i]` 一個 half 0.08 的方塊;繩:每個 `self.rope.x[i]` 一個半徑 0.06 的球;軟體:`world.scene.softs[0].pts[i].x` 各一個半徑 0.1 的球 |
| 測試斷言 | 120 tick 後旗的自由角 y 比初始低至少 0.5 m 且所有座標 `isfinite`;被 pin 的兩點位移 < 1e-4;`abs(rope.length() - 4.0) < 0.2`;軟體質心 y 在 0.3 到 2.0 之間;雜湊相同 |

### 卡 3 城鎮 `game/zone_town.mojo`

| 項目 | 內容 |
|---|---|
| import | `from nav.heightfield import NavBakeConfig`、`from nav.navmesh import NavMesh, bake_navmesh`、`from nav.crowd import Crowd, Orca, CrowdParams`、`from ai.bt import BehaviorTree, BtState, BtHost, bt_tick, RUNNING`、`from ai.blackboard import Blackboard` |
| navmesh | 範圍:x 96 到 160、z 96 到 160(4 格)。三角形:整塊地面兩個三角形,加上每棟建築的方塊(複製 `game/arena.mojo` 第 171 到 215 行的 `_tri`、`_nav_box`、`_make_mesh` 並改座標)。`bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 32))` |
| 群眾 | `self.crowd = Crowd[Orca](Orca(), CrowdParams.default())`;24 名:`_ = self.crowd.add_agent(self.mesh, 街道上的點, 0.3, 1.4)`;目的地清單是 4 個街口 `(112,112)`、`(144,112)`、`(112,144)`、`(144,144)`;`_ = self.crowd.set_target(self.mesh, i, 目的地)`;每 tick `self.crowd.step(self.mesh, DT)`;`self.crowd.arrived[i]` 為真就換下一個目的地 |
| 繪製 | `self.crowd.pos[i]` 各畫身體方塊 + 頭的球(照 `Arena._figure`) |
| 守衛 | 完整複製 `game/arena.mojo` 的 `ChaserHost`(第 125 到 162 行)與 `_think`(第 608 到 655 行)的寫法,數量 2 |
| 測試斷言 | 1200 tick 內至少 12 名到達過一次目的地;`self.crowd.min_separation() > -0.05`;沒有 agent 的位置落在任何建築的 AABB 內;玩家站在守衛前 5 m 時 60 tick 內守衛與玩家距離縮短;雜湊相同 |

### 卡 3b 大遷徙 `game/zone_migration.mojo`(先做 3b-0,再做其餘)

**3b-0 量測(這一步的輸出決定後面的數字,做完先回報)**

1. 複製 `app/bench.mojo` 為 `app/crowd_probe.mojo`,複製 `scripts/bench.py` 為 `scripts/crowd_probe.py`;在 `pixi.toml` 加 `crowd-probe = "python3 scripts/crowd_probe.py"`。
2. 元件照 `build/deps/ludens-core/tests/test_ecs_query.mojo` 開頭定義元件的寫法,定義 `Pos`、`Vel`、`Cold`(`Cold` 放 25 個 `Float64` 欄位)。
3. 世界:`World[<後端>]`,後端名稱先用 `grep -n "^struct .*Backend\|^struct Archetype\|^struct SparseSet" build/deps/ludens-core/ecs/*.mojo` 找出來;照 `build/deps/ludens-core/benchmarks/` 下檔名含 `ecs` 的 bench 的建構方式。
4. 生成:`for i in range(N): _ = w.spawn2(Pos(...), Vel(...))`(三個元件的生成函式名稱以 `grep -n "def spawn" build/deps/ludens-core/ecs/world.mojo` 的結果為準)。
5. 量 `integrate`:
   ```mojo
   def step(mut p: Pos, v: Vel):
       p.x += v.x * DT
       p.z += v.z * DT
   w.for_each2[Pos, Vel](step)
   ```
   每個 N 跑 200 次取中位數,印 `| 實作 | N | system | ns/實體 |` 的 markdown 表格列。
6. 同一個工作用 handle 迴圈(`for e in w.query2[Pos, Vel](): var p = w.get[Pos](e) ...`)與 `oop` 套件各做一次(`oop` 的用法看 `build/deps/ludens-core/benchmarks/` 中含 `oop` 的檔案)。
7. 執行 `pixi run -e wasm crowd-probe`。**把印出的表格原樣回報,然後停**。N 由上一層模型或使用者依第二層的規則決定。

**其餘步驟**在 3b-0 的數字出來後,由第二層以上的模型補寫(格子大小、分層距離、群眾 pass 的頂點格式都取決於量到的數字)。

### 卡 4 訓練場 `game/mocap.mojo` + `game/zone_training.mojo`

| 項目 | 內容 |
|---|---|
| import | `from procedural.anim import AnimClip`、`from procedural.anim_graph import Skeleton, Pose, MotionDB, blend, sample_phase, to_world`、`from procedural.ik import two_bone, foot_plant, look_at` |
| 骨架 | 12 根:0 根(髖)、1 脊、2 頭、3/4 左右上臂、5/6 左右前臂、7/8 左右大腿、9/10 左右小腿、11 未用。`parent = [-1, 0, 1, 1, 1, 3, 4, 0, 0, 7, 8, 0]` |
| 片段 | `var c = AnimClip(12, 30, 30.0)`;`for f in range(30): c.set_key(f, bone, 位置, 旋轉)`。walk:大腿繞 x 軸 `0.5 * sin(2π f/30)`,左右相位差 π;run:振幅 0.9、根位移較快;idle:全部為 rest;旋轉用 `Quat` 的軸角建構(先 `grep -n "def from_axis_angle\|def axis_angle" build/deps/ludens-core/geometry/quat.mojo` 找到實際名稱) |
| motion matching | `var db = MotionDB()`;`db.add_clip(clips, c, 0, [9, 10])`(特徵骨:兩腳);每 6 tick:`var hit = db.query(MotionDB.feature(clips[目前片段], 0, [9, 10], 目前時間))`,讀 `db.clip_of[hit]`、`db.time_of[hit]`;切換時 12 tick 內 `blend(舊姿勢, 新姿勢, w)`,w 由 0 到 1 |
| IK | `var world_pose = to_world(local, parent)`;`var fp = foot_plant(world_pose.p(9), 0.08, 地面高度, Vec3(0.0, 1.0, 0.0, 0.0), 0.3, 0.5)`;`var leg = two_bone(world_pose.p(7), 膝位置, world_pose.p(9), fp.ankle, 前方的 pole)` |
| 繪製 | 每根有父骨的骨頭:中點為位置,half `(0.05, 長度/2, 0.05)`,旋轉為把 y 軸轉到骨頭方向的四元數 |
| 測試斷言 | walk 特徵在 walk 片段中查詢,`clip_of[hit]` 是 walk;`blend(a, b, 0)` 等於 a、`blend(a, b, 1)` 等於 b(逐骨位置差 < 1e-5);腳踏在 0.25 m 高平台上時腳踝 y 與 `平台高 + 0.08` 相差 < 0.02;300 tick 內所有骨頭座標有限;雜湊相同 |

### 卡 5 靶場

依第二層階段 5 的檔案清單逐一建立。每個檔案的範本:

| 新檔 | 複製自 | 要改的地方 |
|---|---|---|
| `game/range_sim.mojo` | `build/deps/ludens-core/gameplay/netcode.mojo` 的 `ArenaSim` | 結構名;crate 改成 3 個固定位置的靶 |
| `app/server_main.mojo` | `app/zone_main.mojo` | `Zone` 換成 `SnapshotServer[RangeSim](RangeSim(2, 3), 3)`;匯出名改 `app_server_*` |
| `shell/web/server_worker.ts` | `shell/web/zone_worker.ts` | 訊息種類改成第二層所列;載入 `./server.wasm` |
| `scripts/range_check.mjs` | `scripts/frontier_check.mjs` | 讀 `window.shell.range` 的數字 |
| 建置 | `scripts/multi_wasm_probe.py` 的 `build_zone` 呼叫 | 入口 `app/server_main.mojo`、輸出 `server.wasm`、`--export "app_server_*"`;加進 `scripts/build_web.py` 與 `build_pages.py` |

主迴圈每 tick 的順序,照 `tests/test_netcode.mojo` 第 186 到 209 行:
```
client.submit(輸入) → up.send(tick, client.outgoing(伺服器節點)) → for m in up.deliver(tick): 送到 Worker
Worker: srv.receive(p, m) → srv.update(tick + 1) → srv.outgoing(p) 送回
down.send(tick, 收到的位元組) → for m in down.deliver(tick): client.receive(伺服器節點, m) → client.update(tick + 1)
```
測試斷言(`tests/frontier_range.mojo`,單行程):`SimLink(9, 2, 0.0, 55)`(約 150 ms)下跑 600 tick,預測客戶端與伺服器的玩家位置差每 tick < 0.75 m,停止輸入 60 tick 後 < 0.01 m;對移動中的靶以 9 tick 前的畫面瞄準射擊:`rewind_ray_cast(scene, ring, tick - 9, origin, dir, 100.0, filter)` 命中,而同一條光線用目前場景的 `raycast` 未命中;兩端 `world_hash()` 在停止輸入後相等。

## 階段 6、7(第三層只到「先查清楚再動手」)

這兩階段依賴 wgpu-mojo 網頁轉譯層的現況,我還沒有逐函式確認,所以不提供可直接照抄的步驟。執行者先做下列查核,把結果交給第二層以上的模型決定下一步:

```
cd /home/user/ludens-shell/build/deps/wgpu-mojo
cat web/implemented.txt | sort                       # 目前網頁可用的 63 個函式
grep -n "Sampler\|WriteTexture\|Comparison\|StorageTexture" web/implemented.txt web/*.mjs | head -40
ls tests | grep -i web
```
回報三件事:(1) `CreateSampler`、`QueueWriteTexture`、depth 比較取樣、storage texture 各自是「已有 / 沒有」;(2) 網頁測試怎麼跑(哪個 pixi task);(3) `app/render3d.mojo` 中 WGSL 的 `struct` 與 binding 清單。

---

## 驗證總表

| 檢查 | 指令 | 涵蓋 |
|---|---|---|
| 規則與確定性 | `pixi run -e wasm test-game` | 每區的斷言與雜湊 |
| 原生對 wasm | `pixi run -e wasm game-parity` | arena 與 frontier 雜湊 |
| 瀏覽器 | `pixi run -e wasm build-pages --check`(連 3 次) | 鍵盤、觸控、frontier 串流與各區、之後的 range |
| 多 wasm | `pixi run -e wasm multi-wasm-probe` | Worker 內雜湊與原生相同 |
| 既有閘門 | CI:`parity-gate`、`check-layout`、`test-pad`、`test-vpad`、`test-cli` 等 | 不退步 |
| 部署 | `curl -sS https://hundo1018.github.io/ludens-engine/build.txt` | 線上版本 |

無法由我驗證:真實 GPU 與手機上的幀率、手感、聲音。每階段上線後請使用者試玩。

## 風險

- `EmbedWorld.physics_tick` 是否推進軟體未確認(卡 2b 有查核步驟)。
- `ray_cast_batch` 自由函式在 `f` 之後的參數未抄錄;階段 6 使用前要先讀 `collision/world_query.mojo:756`。
- 卡 4 的四元數建構函式名稱未確認(卡內有 grep 步驟)。
- 第三層對階段 6、7 只寫到查核,因為轉譯層現況未確認;我沒有把不確定的內容寫成可照抄的步驟。
- 階段 3b 的實體數沒有預先承諾的數字;wasm 與真實 GPU 上能跑多少要等 3b-0 的量測。報告中的 ECS 數字是原生、N = 4000 的,不能直接外推到 wasm 與 10 萬個。
- 在精簡的全量更新上 OOP 基準與 ECS 一樣快(實測 0.83 對 0.76 ns);示範若只做這種工作,切換實作時看不出差別。階段 3b 用帶冷資料的實體與只讀少數欄位的 system 來避免這個誤導,HUD 上兩種情況都列出。

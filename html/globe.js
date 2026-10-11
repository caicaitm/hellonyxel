/* globe.js —— darknet 系列页面共用的伪 3D 方块地球（黑白 · 太空俯瞰 · 可拖动）
 * 页面只需提供 <canvas id="globe"></canvas>；没有该画布的页面引用本文件也不会报错。
 * 包含：大陆点阵渲染 / 拖动惯性 + 自转 / 轨道倒三角卫星 / 彩虹信息访问模拟。 */
(function () {
  "use strict";
  var canvas = document.getElementById("globe");
  if (!canvas) return;                    /* 本页没有地球 → 直接跳过 */
  var ctx = canvas.getContext("2d");
  /* ============================================================
   * 伪 3D 方块地球（黑白 · 太空俯瞰 · 可拖动）
   * 原理：内嵌简化大陆多边形（经纬度）→ 栅格化成陆地点阵 →
   *       每帧做 3D 旋转 + 正交投影，正面半球画白色方块；
   *       方块尺寸 / 亮度随深度变化 → 伪 3D。海洋不画。
   * ============================================================ */
  var RAD = Math.PI / 180;

  /* 简化大陆轮廓（[lon,lat, ...] 顶点序列，低精度但可辨识） */
  var POLYS = [
    /* 北美（含中美，哈德逊湾凹入）*/
    [-168,66,-166,61,-158,58,-152,60,-146,61,-140,60,-136,57,-131,54,-127,50,-124,46,-124,41,-121,36,-117,33,-113,28,-109,23,-105,20,-97,16,-92,15,-87,13,-83,9,-78,9,
     -83,11,-87,16,-89,18,-87,21,-90,22,-96,26,-94,29,-89,29,-84,30,-81,25,-80,27,-81,31,-77,34,-74,39,-70,42,-66,45,-60,47,-65,49,-58,51,-55,52,-60,55,-64,58,-70,60,-78,62,
     -85,64,-92,63,-94,58,-91,55,-85,55,-82,52,-79,54,-82,58,-85,62,-88,64,
     -95,68,-105,68,-115,69,-125,70,-135,69,-145,70,-155,71,-163,70],
    /* 格陵兰 */
    [-45,60,-43,64,-40,65,-32,68,-22,70,-20,75,-30,80,-40,83,-55,82,-62,78,-58,74,-54,69,-52,64,-48,61],
    /* 南美 */
    [-77,8,-72,12,-64,11,-60,9,-55,6,-51,4,-50,0,-47,-1,-44,-3,-38,-5,-35,-8,-37,-12,-39,-17,-42,-22,-48,-25,-53,-32,-57,-35,-58,-38,-62,-40,-65,-44,-67,-48,-68,-52,-66,-55,-71,-54,-74,-50,-74,-44,-73,-39,-71,-33,-70,-25,-70,-18,-76,-14,-79,-8,-81,-4,-80,1,-78,6],
    /* 非洲 */
    [-6,35,-2,35,4,37,10,37,11,34,19,31,25,32,31,31,34,27,36,22,38,18,43,12,47,11,51,12,50,8,46,3,41,-2,39,-7,36,-14,35,-20,33,-26,28,-33,22,-35,18,-33,15,-27,12,-19,13,-11,9,-2,9,4,4,6,-3,5,-8,4,-13,8,-17,13,-17,18,-14,23,-10,28,-6,33],
    /* 欧亚（地中海 / 黑海 / 波罗的海 / 波斯湾 为边界凹入）*/
    [-9,37,-9,43,-2,44,-1,46,-4,48,0,49,4,51,8,54,9,55,10,58,8,57,10,55,12,54,15,54,19,55,21,56,24,58,28,60,25,60,22,61,21,64,25,66,22,66,19,63,18,60,15,56,13,55,11,58,7,58,5,60,5,62,10,64,14,67,18,69,24,71,28,71,33,69,40,66,44,67,52,68,60,69,68,70,72,72,80,73,90,74,100,77,105,78,112,76,120,74,130,72,140,72,150,70,160,69,170,67,178,65,172,61,165,60,162,56,158,52,155,50,152,55,147,55,141,54,137,49,135,44,131,43,128,39,126,35,122,37,120,32,118,25,110,20,108,17,106,11,105,9,103,10,100,13,100,7,104,1,100,3,98,8,97,15,94,16,91,22,86,20,82,16,80,12,77,8,73,16,70,21,66,25,61,25,57,27,53,25,50,29,48,30,51,27,54,24,57,21,55,17,52,14,45,12,43,13,39,17,35,28,34,30,34,36,36,36,30,36,27,37,27,40,29,41,35,42,41,41,41,43,37,45,34,46,31,46,29,45,28,43,25,41,24,40,23,38,22,37,20,40,19,42,16,44,13,45,16,42,18,40,16,38,12,42,10,44,7,43,3,42,0,39,-2,36,-5,36,-7,37],
    /* 英国 / 爱尔兰 / 冰岛 */
    [-5,50,-4,53,-3,56,-5,58,-6,56,-5,53],
    [-10,52,-8,54,-7,55,-10,55],
    [-22,64,-18,63,-14,65,-17,66,-22,66],
    /* 日本弧 */
    [130,32,132,34,136,35,140,36,141,39,142,43,144,44,142,40,140,35,135,33,131,31],
    /* 东南亚群岛 */
    [95,5,98,3,103,-2,106,-5,104,-6,100,-1,95,3],
    [105,-7,110,-7,114,-8,113,-9,106,-8],
    [109,2,113,4,117,6,119,2,116,-2,110,-3,108,-1],
    [119,1,121,-1,122,-4,120,-5,119,-2],
    [131,-1,136,-2,141,-3,146,-6,147,-8,143,-8,138,-7,134,-4],
    [120,18,122,16,124,11,126,7,123,8,120,14],
    /* 南亚小岛 */
    [80,9,82,7,80,6,79,8],
    /* 加勒比 */
    [-84,22,-79,22,-74,20,-77,20,-82,22],
    [-74,19,-70,19,-72,18,-74,18],
    /* 马达加斯加 */
    [49,-12,50,-16,47,-25,44,-22,44,-16],
    /* 澳大利亚 / 塔斯马尼亚 */
    [114,-22,113,-26,115,-33,118,-35,124,-33,129,-32,133,-32,137,-35,140,-38,146,-39,150,-37,153,-30,153,-25,149,-20,146,-17,143,-14,142,-11,139,-14,136,-12,132,-11,128,-14,124,-16,118,-20],
    [145,-41,148,-40,148,-43,145,-43],
    /* 新西兰 */
    [173,-35,176,-38,178,-38,176,-40,174,-40],
    [172,-41,174,-42,171,-44,168,-46,166,-46,170,-42],
    /* 高纬岛屿 */
    [12,78,20,79,22,80,15,80],
    [53,71,58,73,62,76,66,76,60,73,55,71]
  ];
  var ANTARCTIC_LAT = -71;   /* 该纬度以南全部视为陆地（南极冰盖）*/

  /* 多边形 bbox 预计算（加速栅格化）*/
  var BOXES = POLYS.map(function (pt) {
    var minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9;
    for (var i = 0; i < pt.length; i += 2) {
      if (pt[i] < minx) minx = pt[i];
      if (pt[i] > maxx) maxx = pt[i];
      if (pt[i + 1] < miny) miny = pt[i + 1];
      if (pt[i + 1] > maxy) maxy = pt[i + 1];
    }
    return [minx, miny, maxx, maxy];
  });

  /* 射线法：点是否在多边形内 */
  function inPoly(lon, lat, pt) {
    var inside = false;
    for (var i = 0, j = pt.length - 2; i < pt.length; j = i, i += 2) {
      var xi = pt[i], yi = pt[i + 1], xj = pt[j], yj = pt[j + 1];
      if (((yi > lat) !== (yj > lat)) &&
          (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  function isLand(lon, lat) {
    if (lat <= ANTARCTIC_LAT) return true;
    for (var k = 0; k < POLYS.length; k++) {
      var b = BOXES[k];
      if (lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3]) continue;
      if (inPoly(lon, lat, POLYS[k])) return true;
    }
    return false;
  }

  /* 栅格化：等面积步长（高纬度经度步长放大），存单位球坐标 */
  var PX = [], PY = [], PZ = [];   /* 单位球坐标（未旋转）*/
  (function rasterize() {
    var STEP = 1.2;
    for (var lat = -88; lat <= 88; lat += STEP) {
      var cl = Math.cos(lat * RAD);
      var floor = lat <= ANTARCTIC_LAT ? 0.34 : 0.18;   /* 南极冰盖点更密 */
      var lonStep = STEP / Math.max(floor, cl);
      for (var lon = -180; lon < 180; lon += lonStep) {
        if (!isLand(lon, lat)) continue;
        var la = lat * RAD, lo = lon * RAD;
        PX.push(Math.cos(la) * Math.sin(lo));
        PY.push(Math.sin(la));
        PZ.push(Math.cos(la) * Math.cos(lo));
      }
    }
  })();

  /* ---- 渲染 ---- */
  var dpr = Math.max(1, window.devicePixelRatio || 1);
  var cssW = 0, cssH = 0, R = 0, cx0 = 0, cy0 = 0;

  function resize() {
    /* 全出血：画布撑满视口宽（球心水平居中），弧线只会被视口边缘/底边自然裁切，
       不会出现"页面内部悬空断口" */
    cssW = document.documentElement.clientWidth;
    cssH = 520;
    R = cssH * 1.5;
    cx0 = cssW / 2;
    cy0 = cssH + R / 3;   /* 球顶触画布顶，露出高度 = 2R/3 = 1/3 直径 */
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
    canvas.style.width = cssW + "px";
    canvas.style.height = cssH + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize();
  window.addEventListener("resize", resize);

  /* 旋转状态：自转 + 拖动 + 惯性（俯仰无限制：可自由翻转，北极转到画面底部也允许）*/
  var rotY = 1.75, rotX = 0.55;         /* 弧度；初始正对北美，rotX = 太空俯瞰的倾角 */
  var velY = 0, velX = 0;               /* 拖动惯性 */
  var dragging = false, lastX = 0, lastY = 0;
  var AUTO = 0.0011;                    /* 每帧自转 */

  /* 角度归一化到 [-π, π]（自由翻转后防止无限累积）*/
  function wrapPi(a) {
    a = a % (Math.PI * 2);
    if (a > Math.PI) a -= Math.PI * 2;
    if (a < -Math.PI) a += Math.PI * 2;
    return a;
  }

  /* 亮度分桶（减少 fillStyle 切换）*/
  var BUCKETS = 5;
  var bucketIdx = new Int8Array(PX.length);

  /* ---- 人造卫星（倒三角）：绑在地球坐标系里随地球旋转，同时在各自轨道上缓慢漂移 ---- */
  var SATS = [];
  (function initSats() {
    for (var i = 0; i < 120; i++) {
      /* 均匀随机初始方向 */
      var u = Math.random() * 2 - 1;
      var th = Math.random() * Math.PI * 2;
      var rxy = Math.sqrt(1 - u * u);
      var v = [rxy * Math.sin(th), u, rxy * Math.cos(th)];
      /* 轨道轴：随机方向，避开与位置向量近平行（否则轨道面退化）*/
      var a;
      while (true) {
        var u2 = Math.random() * 2 - 1;
        var t2 = Math.random() * Math.PI * 2;
        var r2 = Math.sqrt(1 - u2 * u2);
        a = [r2 * Math.sin(t2), u2, r2 * Math.cos(t2)];
        if (Math.abs(a[0] * v[0] + a[1] * v[1] + a[2] * v[2]) < 0.9) break;
      }
      SATS.push({
        v: v, a: a,
        w: (0.02 + Math.random() * 0.10) * (Math.random() < 0.5 ? -1 : 1),  /* 轨道角速度 rad/s */
        h: 1.06 + Math.random() * 0.50,    /* 轨道半径（相对地球半径）*/
        s: 5 + Math.random() * 7,          /* 基础尺寸 */
        blink: Math.random() < 0.3,        /* 部分卫星信标闪烁 */
        bp: Math.random() * Math.PI * 2
      });
    }
  })();

  /* Rodrigues 旋转：v 绕单位轴 a 转 ang */
  function rotAxis(v, a, ang) {
    var c = Math.cos(ang), s = Math.sin(ang);
    var dot = a[0] * v[0] + a[1] * v[1] + a[2] * v[2];
    var rx = a[1] * v[2] - a[2] * v[1];
    var ry = a[2] * v[0] - a[0] * v[2];
    var rz = a[0] * v[1] - a[1] * v[0];
    return [
      v[0] * c + rx * s + a[0] * dot * (1 - c),
      v[1] * c + ry * s + a[1] * dot * (1 - c),
      v[2] * c + rz * s + a[2] * dot * (1 - c)
    ];
  }

  var lastT = 0, simT = 0;

  /* ---- 信息访问模拟：彩虹传输（起点/终点随机点亮同色 + 抛物线飞行）---- */
  var RAINBOW = ["#ff5252", "#ff9f2e", "#ffe14d", "#4dff88", "#4de1ff", "#5a7cff", "#c25aff"];

  /* 城市节点：从陆地点阵里随机挑一批，作为传输端点（与卫星同池）*/
  var CITY_N = 90;
  var cityIdx = [];
  (function pickCities() {
    var used = {};
    while (cityIdx.length < CITY_N && cityIdx.length < PX.length) {
      var ii = (Math.random() * PX.length) | 0;
      if (used[ii]) continue;
      used[ii] = 1;
      cityIdx.push(ii);
    }
  })();
  var cityMark = new Int8Array(PX.length);
  var cityRank = new Int32Array(PX.length);
  var cityXY = new Float32Array(CITY_N * 2);   /* 每帧更新的屏幕坐标 */
  var cityT = new Float32Array(CITY_N);        /* 深度 0..1（决定方块尺寸）*/
  var cityVis = new Int8Array(CITY_N);         /* 本帧是否可见（正面且在画面内）*/
  (function bindCities() {
    for (var i = 0; i < cityIdx.length; i++) {
      cityMark[cityIdx[i]] = 1;
      cityRank[cityIdx[i]] = i;
    }
  })();

  var satXY = new Float32Array(SATS.length * 2);
  var satT = new Float32Array(SATS.length);
  var satVis = new Int8Array(SATS.length);

  var transfers = [];        /* 进行中的信息访问 */
  var nextTransfer = 1.0;    /* 距下一次触发的秒数 */

  function render(ts) {
    if (lastT === 0) lastT = ts;
    var dt = Math.min(0.05, (ts - lastT) / 1000);   /* 切后台回来不跳变 */
    lastT = ts;
    simT += dt;

    /* 自转 + 惯性衰减（角度归一化，自由翻转无极限）*/
    if (!dragging) {
      rotY = wrapPi(rotY + velY);
      rotX = wrapPi(rotX + velX);
      velY *= 0.95; velX *= 0.92;
      if (Math.abs(velY) < AUTO) { velY = 0; velX = 0; rotY = wrapPi(rotY + AUTO); }
    }
    var sy = Math.sin(rotY), cy = Math.cos(rotY);
    var sx = Math.sin(rotX), cx = Math.cos(rotX);

    ctx.clearRect(0, 0, cssW, cssH);

    /* 球体轮廓环（近景下即"地平线"，勾出行星弧线）*/
    ctx.beginPath();
    ctx.arc(cx0, cy0, R + 3, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(255,255,255,0.16)";
    ctx.lineWidth = 1;
    ctx.stroke();

    /* 陆地白方块：分桶收集，亮桶后画 */
    var buckets = [];
    for (var b = 0; b < BUCKETS; b++) buckets.push([]);
    for (var i = 0; i < PX.length; i++) {
      var x0 = PX[i], y0 = PY[i], z0 = PZ[i];
      var x1 = x0 * cy + z0 * sy;
      var z1 = z0 * cy - x0 * sy;
      var y2 = y0 * cx - z1 * sx;
      var z2 = y0 * sx + z1 * cx;
      if (z2 <= 0.04) {
        if (cityMark[i]) cityVis[cityRank[i]] = 0;   /* 转到背面 → 不可见 */
        continue;
      }
      var px = cx0 + x1 * R, py = cy0 - y2 * R;
      var bk = bucketIdx[i] = (z2 * (BUCKETS - 0.01)) | 0;
      buckets[bk].push(px, py, z2);
      if (cityMark[i]) {
        var ci = cityRank[i];
        cityXY[ci * 2] = px; cityXY[ci * 2 + 1] = py;
        cityT[ci] = (bk + 0.5) / BUCKETS;
        cityVis[ci] = (px >= 0 && px <= cssW && py >= 0 && py <= cssH) ? 1 : 0;
      }
    }
    for (b = 0; b < BUCKETS; b++) {
      var arr = buckets[b];
      if (!arr.length) continue;
      var t = (b + 0.5) / BUCKETS;                 /* 该桶深度 0..1 */
      var s = (8 + 7 * t) * (R / 780);             /* 近大远小，略小于点距 → 保留点阵颗粒感 */
      ctx.fillStyle = "rgba(255,255,255," + (0.16 + 0.84 * t * t).toFixed(3) + ")";
      for (var j = 0; j < arr.length; j += 3) {
        ctx.fillRect(arr[j] - s * 0.5, arr[j + 1] - s * 0.5, s, s);
      }
    }

    /* 人造卫星（倒三角）：与陆地同一旋转矩阵 → 拖动地球时一并移动；
       各自在轨道轴上缓慢漂移（"时刻飘着"）；被地球挡住的（背面且投影在轮廓内）不画。*/
    for (var si = 0; si < SATS.length; si++) {
      var st = SATS[si];
      st.v = rotAxis(st.v, st.a, st.w * dt);
      var vx = st.v[0], vy = st.v[1], vz = st.v[2];
      var x1s = vx * cy + vz * sy;
      var z1s = vz * cy - vx * sy;
      var y2s = vy * cx - z1s * sx;
      var z2s = vy * sx + z1s * cx;
      var px = cx0 + x1s * R * st.h;
      var py = cy0 - y2s * R * st.h;
      var ox = px - cx0, oy = py - cy0;
      if (z2s <= 0 && ox * ox + oy * oy < R * R) { satVis[si] = 0; continue; }   /* 被地球挡住 */
      var tt = Math.max(0, Math.min(1, (z2s + 1) * 0.5));     /* 深度 0..1（背面→正面）*/
      satXY[si * 2] = px; satXY[si * 2 + 1] = py; satT[si] = tt;
      satVis[si] = (px >= -24 && px <= cssW + 24 && py >= -24 && py <= cssH + 24) ? 1 : 0;
      var alpha = 0.34 + 0.62 * tt;
      if (st.blink) alpha *= 0.55 + 0.45 * (0.5 + 0.5 * Math.sin(simT * 3.2 + st.bp));
      var sz = st.s * (0.85 + 0.3 * z2s) * (R / 780);
      /* 倒三角（▽）：底边在上、顶点朝下 */
      ctx.beginPath();
      ctx.moveTo(px - sz * 0.62, py - sz * 0.45);
      ctx.lineTo(px + sz * 0.62, py - sz * 0.45);
      ctx.lineTo(px, py + sz * 0.72);
      ctx.closePath();
      ctx.fillStyle = "rgba(255,255,255," + alpha.toFixed(3) + ")";
      ctx.fill();
    }

    /* ---- 信息访问模拟：触发 + 推进 + 绘制 ---- */
    updateTransfers(dt);
    for (var ti = 0; ti < transfers.length; ti++) drawTransfer(transfers[ti]);
    drawActiveEnds();

    requestAnimationFrame(render);
  }
  requestAnimationFrame(render);


  /* 传输端点的当前屏幕坐标（不可见 → null）*/
  function endXY(e) {
    if (e.type === "city") {
      return cityVis[e.i] ? [cityXY[e.i * 2], cityXY[e.i * 2 + 1], cityT[e.i]] : null;
    }
    return satVis[e.i] ? [satXY[e.i * 2], satXY[e.i * 2 + 1], satT[e.i]] : null;
  }

  /* 传输状态机推进（独立于渲染，便于测试）*/
  function updateTransfers(dt) {
    nextTransfer -= dt;
    if (nextTransfer <= 0 && transfers.length < 9) {
      nextTransfer = 0.5 + Math.random() * 1.0;
      spawnTransfer();
    }
    for (var ti = transfers.length - 1; ti >= 0; ti--) {
      var tr = transfers[ti];
      if (tr.state === "fly") {
        tr.t += dt;
        var alive = endXY(tr.src) != null && endXY(tr.dst) != null;
        if (!alive) {
          /* 端点转到地球背面 → 传输中断，立即恢复白色并移除 */
          transfers.splice(ti, 1);
        } else if (tr.t >= tr.dur) {
          /* 落地：起点/终点恢复白色，留下扩散环后消失 */
          tr.state = "land";
          tr.fade = 0.4;
        }
      } else {
        tr.fade -= dt;
        if (tr.fade <= 0) transfers.splice(ti, 1);
      }
    }
  }

  /* 随机发起一次信息访问：随机彩虹色点亮起点，并让另一元素变成相同颜色作为终点 */
  function spawnTransfer() {
    var pool = [];
    for (var i = 0; i < CITY_N; i++) if (cityVis[i]) pool.push({ type: "city", i: i });
    for (i = 0; i < SATS.length; i++) if (satVis[i]) pool.push({ type: "sat", i: i });
    if (pool.length < 2) return;
    var s = pool[(Math.random() * pool.length) | 0];
    var d = pool[(Math.random() * pool.length) | 0];
    var guard = 0;
    while (s.type === d.type && s.i === d.i && guard++ < 8) {
      d = pool[(Math.random() * pool.length) | 0];
    }
    if (s.type === d.type && s.i === d.i) return;
    transfers.push({
      src: s, dst: d,
      color: RAINBOW[(Math.random() * RAINBOW.length) | 0],
      t: 0, dur: 1.0 + Math.random() * 0.7,
      state: "fly", fade: 0
    });
  }

  /* 彩色高亮的传输端点（覆盖在白色方块/倒三角之上；落地即不再绘制 → 恢复白色）*/
  function drawActiveEnds() {
    for (var i = 0; i < transfers.length; i++) {
      var tr = transfers[i];
      if (tr.state !== "fly") continue;
      var e = endXY(tr.src);
      if (e != null) drawEnd(e, tr.color, tr.src.type);
      e = endXY(tr.dst);
      if (e != null) drawEnd(e, tr.color, tr.dst.type);
    }
  }

  function drawEnd(e, col, type) {
    ctx.fillStyle = col;
    ctx.strokeStyle = "rgba(255,255,255,0.9)";
    ctx.lineWidth = 1;
    if (type === "city") {
      var s = (10 + 9 * e[2]) * (R / 780) * 1.35;
      ctx.fillRect(e[0] - s * 0.5, e[1] - s * 0.5, s, s);
      ctx.strokeRect(e[0] - s * 0.5, e[1] - s * 0.5, s, s);
    } else {
      var sz = (5 + 8 * e[2]) * (R / 780) * 1.3;
      ctx.beginPath();
      ctx.moveTo(e[0] - sz * 0.62, e[1] - sz * 0.45);
      ctx.lineTo(e[0] + sz * 0.62, e[1] - sz * 0.45);
      ctx.lineTo(e[0], e[1] + sz * 0.72);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
    }
  }

  /* 抛物线传输：二次贝塞尔从起点生长到终点，前端带亮点；落地后只留扩散环 */
  function drawTransfer(tr) {
    var a = endXY(tr.src), b = endXY(tr.dst);
    if (a == null || b == null) return;
    var P0x = a[0], P0y = a[1], P2x = b[0], P2y = b[1];
    var dist = Math.hypot(P2x - P0x, P2y - P0y);
    var arcH = Math.min(240, dist * 0.35 + 50);
    var P1x = (P0x + P2x) * 0.5, P1y = Math.min(P0y, P2y) - arcH;
    var u = Math.min(1, tr.t / tr.dur);
    /* de Casteljau：曲线 0..u 段的子控制点 */
    var Qx = P0x + (P1x - P0x) * u, Qy = P0y + (P1y - P0y) * u;
    var Bx = Qx + (P2x - Qx) * u, By = Qy + (P2y - Qy) * u;

    ctx.globalAlpha = 0.9;
    ctx.strokeStyle = tr.color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(P0x, P0y);
    ctx.quadraticCurveTo(Qx, Qy, Bx, By);
    ctx.stroke();
    /* 前端亮点（"数据包"）*/
    ctx.beginPath();
    ctx.arc(Bx, By, 3, 0, Math.PI * 2);
    ctx.fillStyle = tr.color;
    ctx.fill();
    ctx.globalAlpha = 1;

    if (tr.state === "land") {
      var p = 1 - tr.fade / 0.4;
      ctx.globalAlpha = (1 - p) * 0.8;
      ctx.strokeStyle = tr.color;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(b[0], b[1], 6 + 26 * p, 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
  }

  /* ---- 拖动（Pointer Events，鼠标 / 触摸通用）---- */
  canvas.addEventListener("pointerdown", function (e) {
    dragging = true;
    lastX = e.clientX; lastY = e.clientY;
    velY = 0; velX = 0;
    canvas.classList.add("dragging");
    if (canvas.setPointerCapture) canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", function (e) {
    if (!dragging) return;
    var dx = e.clientX - lastX, dy = e.clientY - lastY;
    lastX = e.clientX; lastY = e.clientY;
    rotY = wrapPi(rotY + dx * 0.006);
    rotX = wrapPi(rotX + dy * 0.006);   /* 俯仰无限制：可以一路翻到北极朝下 */
    velY = dx * 0.0018;   /* 松手惯性取最后一次移动速度 */
    velX = dy * 0.0012;
  });
  function endDrag() {
    dragging = false;
    canvas.classList.remove("dragging");
  }
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);
})();
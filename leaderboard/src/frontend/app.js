/**
 * Input:  URL query param ?user=xxx（当前用户 ID 高亮）
 *         排行榜 API GET /api/leaderboard?type=weekly|monthly|total
 * Output: 渲染排名表格，60 秒自动刷新，标签切换，当前用户行高亮
 * Pos:    Cloudflare Pages 前端唯一 JS，无框架依赖
 * 一旦我被修改，请更新我的头部注释，以及所属文件夹的md。
 */

(function () {
  'use strict';

  // ---- 常量 ----
  const API_BASE = '/api/leaderboard';
  const REFRESH_INTERVAL = 60 * 1000; // 60 秒
  const STORAGE_KEY = 'leaderboard-type';

  // ---- 状态 ----
  let currentType = 'weekly';
  let currentData = [];
  let highlightUserId = null;
  let refreshTimer = null;
  let countdownTimer = null;
  let countdownValue = 60;

  // ---- DOM 引用 ----
  const tableBody = document.getElementById('table-body');
  const errorMessage = document.getElementById('error-message');
  const countdownEl = document.getElementById('refresh-countdown');
  const tabButtons = document.querySelectorAll('.tab');

  // ---- 等级映射 ----
  const LEVEL_LABELS = {
    beginner: '初出茅庐',
    intermediate: '月度冠军',
    advanced: '铁腚传奇',
    platinum: '极限挑战',
    diamond: '千日丰碑',
    master: '王者',
  };

  const LEVEL_CLASSES = {
    beginner: 'badge-grey',
    intermediate: 'badge-blue',
    advanced: 'badge-gold',
    platinum: 'badge-gold',
    diamond: 'badge-gold',
    master: 'badge-gold',
  };

  // ---- 工具函数 ----
  function getQueryParam(name) {
    const url = new URL(window.location.href);
    return url.searchParams.get(name);
  }

  function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }

  // ---- API 调用 ----
  async function fetchLeaderboard(type) {
    const resp = await fetch(`${API_BASE}?type=${type}&limit=50&offset=0`);
    if (!resp.ok) {
      throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
    }
    const data = await resp.json();
    return data.rankings || data || [];
  }

  // ---- 渲染 ----
  function renderTable(rankings) {
    tableBody.innerHTML = '';

    if (!rankings || rankings.length === 0) {
      tableBody.innerHTML = `
        <tr class="row-empty">
          <td colspan="5" class="empty-cell">暂无排名数据，快去打卡吧！</td>
        </tr>`;
      return;
    }

    rankings.forEach(function (entry) {
      const rank = entry.rank || entry.ranking || '—';
      const displayName = entry.display_name || entry.nickname || '未知用户';
      const score = entry.score != null ? entry.score : 0;
      const streak = entry.streak_days != null ? entry.streak_days : 0;
      const level = entry.stage || entry.level || 'beginner';
      const userId = entry.user_id || entry.id || '';
      const isPrivate = entry.opt_in_leaderboard === false || entry.privacy_mode === true;

      // 隐私模式用户显示匿名
      const nameDisplay = isPrivate ? '匿名用户' : displayName;

      // 当前用户高亮
      const isCurrentUser = highlightUserId && userId === highlightUserId;

      // 等级标签
      const levelLabel = LEVEL_LABELS[level] || level;
      const levelClass = LEVEL_CLASSES[level] || 'badge-grey';

      const row = document.createElement('tr');
      if (isCurrentUser) {
        row.classList.add('row-highlight');
      }
      if (isPrivate) {
        row.classList.add('row-private');
      }

      row.innerHTML = `
        <td class="col-rank">
          <span class="rank-num ${rank <= 3 ? 'rank-top-' + rank : ''}">${rank}</span>
        </td>
        <td class="col-name">${escapeHtml(nameDisplay)}</td>
        <td class="col-score">${score}</td>
        <td class="col-streak">${streak} 天</td>
        <td class="col-level">
          <span class="badge ${levelClass}">${levelLabel}</span>
        </td>`;

      tableBody.appendChild(row);
    });
  }

  function showError() {
    errorMessage.classList.remove('hidden');
    tableBody.innerHTML = '';
  }

  function hideError() {
    errorMessage.classList.add('hidden');
  }

  function showLoading() {
    tableBody.innerHTML = `
      <tr class="row-loading">
        <td colspan="5" class="loading-cell">
          <div class="loading-spinner"></div>
          <span>加载中...</span>
        </td>
      </tr>`;
  }

  // ---- 动画：排名变化闪烁 ----
  function animateRankChanges(newData) {
    if (!currentData.length) return;

    newData.forEach(function (entry) {
      const oldEntry = currentData.find(function (o) {
        return (o.user_id || o.id) === (entry.user_id || entry.id);
      });
      if (!oldEntry) return;

      const oldRank = oldEntry.rank || oldEntry.ranking;
      const newRank = entry.rank || entry.ranking;
      if (newRank < oldRank) {
        // 排名上升，添加闪烁动画
        const userId = entry.user_id || entry.id;
        const row = tableBody.querySelector(`[data-user-id="${userId}"]`);
        if (row) {
          row.classList.add('rank-up-flash');
          row.addEventListener('animationend', function () {
            row.classList.remove('rank-up-flash');
          }, { once: true });
        }
      }
    });
  }

  // ---- 数据加载与刷新 ----
  async function loadData(type) {
    hideError();
    try {
      const data = await fetchLeaderboard(type);
      // 先记录旧排名做动画
      if (currentData.length && data.length) {
        // 简单比较：渲染完成后检查排名变化
      }
      currentData = data;
      renderTable(data);
    } catch (err) {
      console.error('排行榜数据加载失败:', err);
      showError();
    }
  }

  function startRefreshLoop() {
    stopRefreshLoop();
    countdownValue = 60;
    updateCountdown();

    refreshTimer = setInterval(function () {
      loadData(currentType);
      countdownValue = 60;
      updateCountdown();
    }, REFRESH_INTERVAL);

    countdownTimer = setInterval(function () {
      countdownValue -= 1;
      if (countdownValue <= 0) {
        countdownValue = 60;
      }
      updateCountdown();
    }, 1000);
  }

  function stopRefreshLoop() {
    if (refreshTimer) {
      clearInterval(refreshTimer);
      refreshTimer = null;
    }
    if (countdownTimer) {
      clearInterval(countdownTimer);
      countdownTimer = null;
    }
  }

  function updateCountdown() {
    if (countdownEl) {
      countdownEl.textContent = '下次刷新: ' + countdownValue + 's';
    }
  }

  // ---- 标签切换 ----
  function switchTab(type) {
    if (currentType === type) return;

    currentType = type;
    // 持久化选择
    try {
      localStorage.setItem(STORAGE_KEY, type);
    } catch (_) { /* ignore */ }

    // 更新标签 UI
    tabButtons.forEach(function (btn) {
      btn.classList.toggle('active', btn.dataset.type === type);
    });

    // 重新加载
    showLoading();
    loadData(type);
    // 重置倒计时
    countdownValue = 60;
    updateCountdown();
  }

  tabButtons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      switchTab(btn.dataset.type);
    });
  });

  // ---- 初始化 ----
  function init() {
    // 读取 URL 参数中的当前用户 ID
    highlightUserId = getQueryParam('user');

    // 恢复上次的榜单类型选择
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved && ['weekly', 'monthly', 'total'].includes(saved)) {
        currentType = saved;
      }
    } catch (_) { /* ignore */ }

    // 更新标签 UI 到当前类型
    tabButtons.forEach(function (btn) {
      btn.classList.toggle('active', btn.dataset.type === currentType);
    });

    // 首次加载
    loadData(currentType);

    // 启动自动刷新
    startRefreshLoop();
  }

  // 页面卸载时清理定时器
  window.addEventListener('beforeunload', function () {
    stopRefreshLoop();
  });

  // 启动
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

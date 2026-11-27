import { endpoint, syncKey } from "./local-config.js";

const alarmName = "google-one-membership";
const membershipURL = "https://one.google.com/settings?expand=upgrade";
let running;

async function readMembership() {
    const url = new URL(location.href);
    if (url.origin !== "https://one.google.com") return null;
    if (!/^\/(?:u\/\d+\/)?settings\/?$/.test(url.pathname) || url.searchParams.get("expand") !== "upgrade") {
        return { issue: "Google One 未打开会员方案页" };
    }

    const headings = document.querySelectorAll("h1,h2,h3,h4,h5,h6,[role=heading]");
    const current = [...headings].find((heading) =>
        /^(?:your current plan|current plan|当前方案|目前方案|當前方案)$/i.test(heading.textContent.trim())
    );
    if (!current) return { issue: "等待当前方案" };

    function planFor(line) {
        const ultra = line.match(/^Google AI Ultra\s*(5|20)\s*(?:x|×|倍)(?:\s*(?:plan|方案|計畫))?$/i);
        if (ultra) return `Google AI Ultra ${ultra[1]}x`;
        const lowerTier = line.match(/^Google AI (Plus|Pro)(?:\s*(?:plan|方案|計畫))?$/i);
        if (lowerTier) return lowerTier[1].toLowerCase() === "pro" ? "Google AI Pro" : "Google AI Plus";
        return null;
    }

    let plan;
    let section = current.parentElement;
    for (let depth = 0; section && section !== document.body && depth < 5; depth += 1) {
        const lines = section.innerText.split("\n").map((line) => line.replace(/\s+/g, " ").trim());
        const names = new Set(lines.map(planFor).filter(Boolean));
        if (names.size > 1) return { issue: "当前方案区域包含多个档位" };
        if (names.size === 1) {
            plan = names.values().next().value;
            break;
        }
        section = section.parentElement;
    }
    if (!plan) return { issue: "当前方案名称未识别" };

    const account = document.querySelector(
        '[aria-label*="Google Account:"],[aria-label*="Google 账号："],[aria-label*="Google 帐号："],[aria-label*="Google 帳戶："]'
    );
    const email = account?.getAttribute("aria-label")?.match(/[\w.%+-]+@[\w.-]+\.[\w]+/)?.[0];
    if (!email) return { issue: "页面没有可核对的账号" };
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(email.toLowerCase()));
    const identity = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    return { account: identity, plan };
}

async function synchronize() {
    const tab = await chrome.tabs.create({ url: membershipURL, active: false });
    try {
        const deadline = Date.now() + 20000;
        let issue = "等待 Google One 页面";
        while (Date.now() < deadline) {
            const state = await chrome.tabs.get(tab.id);
            if (state.status === "complete" && state.url) {
                const url = new URL(state.url);
                if (url.origin !== "https://one.google.com") {
                    throw new Error("Google One 当前账号或登录状态需要核对");
                }
                const [result] = await chrome.scripting.executeScript({
                    target: { tabId: tab.id },
                    func: readMembership
                });
                if (result.result?.issue) issue = result.result.issue;
                if (result.result?.account && result.result.plan) {
                    const response = await fetch(endpoint, {
                        method: "POST",
                        credentials: "omit",
                        redirect: "error",
                        headers: { "Content-Type": "application/json", "X-T3-Plan-Sync": syncKey },
                        body: JSON.stringify(result.result),
                        signal: AbortSignal.timeout(3000)
                    });
                    if (response.status === 409) throw new Error("Google One 账号与反重力账号不一致");
                    if (!response.ok) throw new Error(`本机额度服务拒绝写入 (${response.status})`);
                    await chrome.action.setTitle({ title: `Google One 已同步 · ${result.result.plan}` });
                    return;
                }
            }
            await new Promise((resolve) => setTimeout(resolve, 1000));
        }
        throw new Error(issue);
    } finally {
        await chrome.tabs.remove(tab.id).catch(() => {});
    }
}

function refresh() {
    if (!running) {
        running = synchronize()
            .catch(async (error) => {
                console.warn("Google One 套餐同步", error);
                const reason = /[\u3400-\u9fff]/.test(error.message) ? error.message : "无法执行同步";
                await chrome.action.setTitle({ title: `Google One 未同步 · ${reason}` });
            })
            .finally(() => { running = undefined; });
    }
    return running;
}

async function start() {
    if (!await chrome.alarms.get(alarmName)) {
        await chrome.alarms.create(alarmName, { periodInMinutes: 360 });
    }
    await refresh();
}

chrome.runtime.onInstalled.addListener(() => { void start(); });
chrome.runtime.onStartup.addListener(() => { void start(); });
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === alarmName) void refresh();
});
chrome.action.onClicked.addListener(() => { void refresh(); });

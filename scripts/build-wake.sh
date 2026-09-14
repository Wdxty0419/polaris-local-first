#!/usr/bin/env bash
set -euo pipefail

echo "===== 1. install deps ====="
npm install
npm install @capacitor/background-runner

echo "===== 2. write runner ====="
mkdir -p public/runners
cat > public/runners/wake-probe.js <<'RUNNER_EOF'
var P={mD:0.50,Dmin:0.20,Dmax:0.80,kRun:0.10,tD:720,mT:0.50,sT:0.10,Tmin:0.25,Tmax:0.75,tT:21600,mX:0.00,sX:0.18,Xmin:-0.40,Xmax:0.40,tX:1500,l0:0.000416667,bD:1.80,bT:1.60,bX:1.20,lmin:0.0000416667,lmax:0.00222222,Mmod:1.00};
function mulberry32(s){s=s|0;return function(){s=(s+0x6D2B79F5)|0;var t=Math.imul(s^(s>>>15),1|s);t=(t+Math.imul(t^(t>>>7),61|t))^t;return((t^(t>>>14))>>>0)/4294967296;};}
function rngFrom(seed,cursor){var r=mulberry32(seed);for(var i=0;i<cursor;i++)r();return r;}
function gaussPair(r){var u=0,v=0;while(u<=0)u=r();while(v<=0)v=r();var s=Math.sqrt(-2*Math.log(u));return[s*Math.cos(2*Math.PI*v),s*Math.sin(2*Math.PI*v)];}
function drawTheta(r){var u=0;while(u<=0)u=r();return-Math.log(u);}
function clamp(v,a,b){return v<a?a:(v>b?b:v);}
function lam(D,T,X){return clamp(P.l0*Math.exp(P.bD*(D-P.mD)+P.bT*(T-P.mT)+P.bX*X)*P.Mmod,P.lmin,P.lmax);}
function advD(D,dt){return clamp(P.mD+(D-P.mD)*Math.pow(2,-dt/P.tD),P.Dmin,P.Dmax);}
function advT(T,dt,r){var k=Math.pow(2,-dt/P.tT);return clamp(P.mT+(T-P.mT)*k+P.sT*Math.sqrt(Math.max(0,1-k*k))*gaussPair(r)[0],P.Tmin,P.Tmax);}
function advX(X,dt,r){var k=Math.pow(2,-dt/P.tX);return clamp(X*k+P.sX*Math.sqrt(Math.max(0,1-k*k))*gaussPair(r)[0],P.Xmin,P.Xmax);}
var STEP=60;
function stepCycle(st,dtSec){var D=st.D,T=st.T,X=st.X,H=st.H,theta=st.theta;var cur=st.entropyCursor;var r=rngFrom(st.entropySeed,cur);var consumed=0,elapsed=0,crossed=false;while(elapsed<dtSec){var sub=Math.min(STEP,dtSec-elapsed);H+=lam(D,T,X)*sub;if(H>=theta){crossed=true;break;}D=advD(D,sub);T=advT(T,sub,r);consumed+=2;X=advX(X,sub,r);consumed+=2;elapsed+=sub;}return{state:{D:D,T:T,X:X,H:H,theta:theta,entropySeed:st.entropySeed,entropyCursor:cur+consumed,cycleStartedAt:st.cycleStartedAt},crossed:crossed};}
function resetCycle(st,nowMs){var r=rngFrom(st.entropySeed,st.entropyCursor);var th=drawTheta(r);return{D:clamp(st.D-P.kRun,P.Dmin,P.Dmax),T:st.T,X:st.X,H:0,theta:th,entropySeed:st.entropySeed,entropyCursor:st.entropyCursor+1,cycleStartedAt:nowMs};}
function createInitial(nowMs){var seed=(nowMs^0xDEADBEEF)>>>0;var r=mulberry32(seed);return{D:P.mD,T:P.mT,X:P.mX,H:0,theta:drawTheta(r),entropySeed:seed,entropyCursor:1,cycleStartedAt:nowMs};}

addEventListener('wakeHeartbeat', function(resolve, reject, args) {
  try {
    var now = Date.now();
    var iso = new Date(now).toISOString();
    var st = null;
    try { var raw = CapacitorKV.get('wake_state').value; if (raw) st = JSON.parse(raw); } catch(e) { st = null; }
    if (!st || typeof st.D !== 'number') { st = createInitial(now); console.log('[wake] init theta=' + st.theta.toFixed(3)); }
    var dt = Math.max(0, (now - st.cycleStartedAt) / 1000);
    var result = stepCycle(st, dt);
    var ns = result.state;
    var crossed = result.crossed;
    var lamNow = lam(ns.D, ns.T, ns.X) * 3600;
    console.log('[wake] dt=' + Math.round(dt) + 's H=' + ns.H.toFixed(3) + '/' + ns.theta.toFixed(3) + ' lam=' + lamNow.toFixed(2) + '/h crossed=' + crossed);
    if (crossed) {
      ns = resetCycle(ns, now);
      console.log('[wake] === WAKE OPPORTUNITY === new theta=' + ns.theta.toFixed(3));
      CapacitorNotifications.schedule([{ id: 9002, title: '小满想找你', body: '（自然醒来）H 跨过了门槛', extra: { polarisKind: 'wake-veil-opportunity', wokeAt: now }, channelId: 'polaris-wake-probe' }]);
    }
    ns.cycleStartedAt = now;
    CapacitorKV.set('wake_state', JSON.stringify(ns));
    var pct = ns.theta > 0 ? Math.round(ns.H / ns.theta * 100) : 0;
    CapacitorNotifications.schedule([{ id: 9001, title: 'Wake Heartbeat', body: 'H=' + ns.H.toFixed(2) + '/' + ns.theta.toFixed(2) + ' (' + pct + '%) lam=' + lamNow.toFixed(1) + '/h', channelId: 'polaris-wake-probe' }]);
    resolve();
  } catch (err) { console.log('[wake] ERR: ' + (err.message||err)); reject(err); }
});
RUNNER_EOF
echo "--- runner written ---"

echo "===== 3. patch useChatTriggerRuntime for wake-veil ====="
cat > /tmp/patch-wake.mjs <<'PATCH_EOF'
import { readFileSync, writeFileSync } from 'fs';
const F = 'src/app/chat/useChatTriggerRuntime.ts';
let c = readFileSync(F, 'utf8');

// add import
c = c.replace(
  "import { selectChatConversations } from './liveConversationCatalog';",
  "import { selectChatConversations } from './liveConversationCatalog';\nimport { LocalNotifications } from '@capacitor/local-notifications';"
);

// add ref
c = c.replace(
  'const [wakeTick, setWakeTick] = useState(0);',
  'const [wakeTick, setWakeTick] = useState(0);\n  const wakeVeilPendingRef = useRef(false);'
);

// add tap listener effect before the timer effect
const TAP_EFFECT = `
  // Wake Veil: notification tap listener
  useEffect(() => {
    if (!startupReady) return;
    if (!Capacitor.isNativePlatform() || !Capacitor.isPluginAvailable('LocalNotifications')) return;
    let cancelled = false;
    let handle: any = null;
    void LocalNotifications.addListener('localNotificationActionPerformed', (action: any) => {
      const extra = action.notification?.extra;
      if (extra && extra.polarisKind === 'wake-veil-opportunity') {
        wakeVeilPendingRef.current = true;
        setWakeTick((prev: number) => prev + 1);
      }
    }).then((h: any) => { if (cancelled) { void h.remove(); } else { handle = h; } });
    return () => { cancelled = true; if (handle) void handle.remove(); };
  }, [startupReady]);

`;
c = c.replace(
  '  useEffect(() => {\n    if (!startupReady) return;\n    const nextRunAt = store.runtime.triggerRules',
  TAP_EFFECT + '  useEffect(() => {\n    if (!startupReady) return;\n    const nextRunAt = store.runtime.triggerRules'
);

// patch main execution effect
const OLD_RULE_CHECK = '    const runtimeState = store.runtime.readLatestState();\n    const [rule] = getDueTriggerRules(runtimeState.triggerRules);\n    if (!rule) return;';

const NEW_RULE_CHECK = `    // Wake Veil: check delivered notifications
    if (Capacitor.isNativePlatform() && !wakeVeilPendingRef.current) {
      void (async () => {
        try {
          const delivered = await LocalNotifications.getDeliveredNotifications();
          const wv = delivered.notifications.find((n: any) => n.extra?.polarisKind === 'wake-veil-opportunity');
          if (wv) {
            await LocalNotifications.removeDeliveredNotifications({ notifications: [wv] });
            wakeVeilPendingRef.current = true;
            setWakeTick((prev: number) => prev + 1);
          }
        } catch {}
      })();
    }

    const runtimeState = store.runtime.readLatestState();
    const [rule] = getDueTriggerRules(runtimeState.triggerRules);
    if (!rule && !wakeVeilPendingRef.current) return;
    if (!rule && wakeVeilPendingRef.current) {
      wakeVeilPendingRef.current = false;
      runningRuleIdRef.current = '__wake-veil__';
      void (async () => {
        try {
          const persona = store.persona.readLatestState().personas[0];
          if (!persona) return;
          const chatState = store.chat.readLatestState();
          const liveConvs = selectChatConversations(chatState.conversations);
          let conv = liveConvs.filter((cv: any) => cv.collaboratorId === persona.id).sort((a: any, b: any) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0] ?? null;
          if (!conv) { const newId = store.chat.createConversation(persona.id); conv = selectChatConversations(store.chat.readLatestState().conversations).find((cv: any) => cv.id === newId) ?? null; }
          if (!conv) return;
          if (generationByConversationIdRef.current[conv.id]?.sending) return;
          const writable = await store.chat.ensureConversationWritable(conv.id);
          if (!writable) return;
          const nextMessages = [...writable.messages];
          const msgCount = nextMessages.length;
          setCommandStatus('Wake Veil 自然醒来');
          const result = await runReply({ conversationId: writable.conversationId, collaboratorId: persona.id, messages: nextMessages });
          if (result.status !== 'aborted' && mountedRef.current) {
            const lcs = store.chat.readLatestState();
            const lss = store.space.readLatestState();
            const lc = lcs.conversations.find((e: any) => e.id === writable.conversationId) ?? null;
            const notif = buildProactiveReplyNotification({ conversation: lc, collaboratorId: persona.id, collaboratorName: persona.name, messageCountBeforeReply: msgCount, currentView: { activeWorld: lss.activeWorld, activeConversationId: lcs.activeConversationId } });
            if (notif) { store.space.enqueueReplyNotification(notif); void postNativeProactiveReplyNotification(notif); }
          }
        } catch (error) {
          setCommandStatus('Wake Veil 触发失败', true);
        } finally {
          if (runningRuleIdRef.current === '__wake-veil__') runningRuleIdRef.current = null;
        }
      })();
      return;
    }
    if (!rule) return;`;

if (!c.includes(OLD_RULE_CHECK)) {
  console.error('[patch] ERROR: anchor not found in useChatTriggerRuntime.ts');
  process.exit(1);
}
c = c.replace(OLD_RULE_CHECK, NEW_RULE_CHECK);
writeFileSync(F, c);
console.log('[patch] useChatTriggerRuntime.ts patched for Wake Veil');
PATCH_EOF
node /tmp/patch-wake.mjs

echo "===== 4. write capacitor config ====="
cat > capacitor.config.ts <<'CONFIG_EOF'
import type { CapacitorConfig } from '@capacitor/cli';
import { KeyboardResize } from '@capacitor/keyboard';

const config: CapacitorConfig = {
  appId: 'com.alyssa.polaris',
  appName: 'Polaris',
  webDir: 'dist',
  server: {
    iosScheme: 'http',
    hostname: 'localhost'
  },
  plugins: {
    CapacitorHttp: {
      enabled: false
    },
    Keyboard: {
      resize: KeyboardResize.None
    },
    LocalNotifications: {
      presentationOptions: ['badge', 'sound', 'banner', 'list']
    },
    BackgroundRunner: {
      label: 'com.polaris.wakeprobe',
      src: 'runners/wake-probe.js',
      event: 'wakeHeartbeat',
      repeat: true,
      interval: 15,
      autoStart: true
    }
  }
};

export default config;
CONFIG_EOF
echo "--- config written ---"

echo "===== 5. patch build.gradle ====="
python3 - <<'PY_EOF'
import io
p = 'android/app/build.gradle'
s = io.open(p, encoding='utf-8').read()
if 'background-runner' in s:
    print('already patched')
else:
    anchor = "'../capacitor-cordova-android-plugins/src/main/libs', 'libs' }"
    if anchor not in s:
        raise SystemExit('ANCHOR MISSING in build.gradle')
    add = "'../capacitor-cordova-android-plugins/src/main/libs', 'libs', '../../node_modules/@capacitor/background-runner/android/src/main/libs' }"
    io.open(p, 'w', encoding='utf-8').write(s.replace(anchor, add))
    print('patched')
PY_EOF

echo "===== 6. build ====="
npm run build
npx cap sync android

echo "===== 7. apk ====="
cd android
chmod +x gradlew
./gradlew assembleDebug --no-daemon
cd ..

echo "===== 8. verify ====="
unzip -l android/app/build/outputs/apk/debug/app-debug.apk | grep -i wake-probe || echo "WARNING: runner not found in APK"
echo "===== done ====="

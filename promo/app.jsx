const { useState, useEffect, useRef } = React;

// ── Icons ─────────────────────────────────────────────────────────────────────
const Icon = ({ name, size = 20, color = 'currentColor', strokeWidth = 1.8 }) => {
  const icons = {
    bolt:       <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>,
    zap:        <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>,
    map:        <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><polygon points="1 6 1 22 8 18 16 22 23 18 23 2 16 6 8 2 1 6"/><line x1="8" y1="2" x2="8" y2="18"/><line x1="16" y1="6" x2="16" y2="22"/></svg>,
    schedule:   <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>,
    chart:      <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>,
    shield:     <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>,
    wifi:       <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M1.42 9a16 16 0 0 1 21.16 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/></svg>,
    download:   <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>,
    chevronL:   <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><polyline points="15 18 9 12 15 6"/></svg>,
    chevronR:   <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><polyline points="9 18 15 12 9 6"/></svg>,
    arrowRight: <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/></svg>,
    users:      <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>,
    settings:   <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>,
    building:   <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="15" x2="21" y2="15"/><line x1="9" y1="3" x2="9" y2="21"/><line x1="15" y1="3" x2="15" y2="21"/></svg>,
    cpu:        <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="6" height="6"/><rect x="2" y="2" width="20" height="20" rx="2" ry="2"/><line x1="9" y1="2" x2="9" y2="9"/><line x1="15" y1="2" x2="15" y2="9"/><line x1="9" y1="15" x2="9" y2="22"/><line x1="15" y1="15" x2="15" y2="22"/><line x1="2" y1="9" x2="9" y2="9"/><line x1="2" y1="15" x2="9" y2="15"/><line x1="15" y1="9" x2="22" y2="9"/><line x1="15" y1="15" x2="22" y2="15"/></svg>,
    file:       <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>,
    leaf:       <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M2 22c1.25-1.25 2.07-2.76 2.74-4.36C6.27 14.36 7 11.72 7 9a7 7 0 1 1 14 0c0 4.63-3.5 8.5-8 9.47"/><path d="M8 22c0-5.5 3.5-9 8-9"/></svg>,
    smartphone: <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>,
    checkCircle:<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>,
  };
  return icons[name] || <span>{name}</span>;
};

// ── Phone Mockup ──────────────────────────────────────────────────────────────
const PhoneMockup = () => (
  <div className="phone-mockup animate-float">
    <div className="phone-frame">
      <div className="phone-screen">
        <img className="phone-screen-img" src="./phone-img.jpg" alt="SmartPowerSwitch app preview" />
      </div>
    </div>
  </div>
);

// ── Carousel ──────────────────────────────────────────────────────────────────
const slides = [
  {
    tag: 'Energy Dashboard',
    title: 'Real-Time Consumption Monitoring',
    desc: 'Live energy readings per building, utility, and device. Track kWh, voltage, current, and cost in Philippine Peso.',
    color: '#EBF7EF',
    accent: '#1A5C35',
    icon: 'chart',
    illustration: 'dashboard',
  },
  {
    tag: 'Campus Map',
    title: 'Interactive Visual Building Map',
    desc: 'Color-coded hotspots show energy levels across the campus. Tap any building for instant details and direct navigation.',
    color: '#E8F5EC',
    accent: '#2E9E52',
    icon: 'map',
    illustration: 'map',
  },
  {
    tag: 'Automation',
    title: 'Smart Scheduling & Automation',
    desc: 'Set schedules globally, per building, utility, or specific device. ESP32 executes relay toggles automatically on time.',
    color: '#EDF7F1',
    accent: '#1A5C35',
    icon: 'schedule',
    illustration: 'schedule',
  },
  {
    tag: 'Analytics',
    title: 'Historical Energy Analytics',
    desc: 'Daily, weekly, monthly, and yearly charts. Export full energy reports as CSV with building and utility breakdowns.',
    color: '#E5F5EA',
    accent: '#2E9E52',
    icon: 'file',
    illustration: 'analytics',
  },
  {
    tag: 'Device Management',
    title: 'ESP32 Device Assignment',
    desc: 'Unique Device IDs burned to ESP32. Admins assign devices to rooms via the app. Relay toggling is admin-only.',
    color: '#EBF7EF',
    accent: '#1A5C35',
    icon: 'cpu',
    illustration: 'device',
  },
  {
    tag: 'User Roles',
    title: 'Admin & Faculty Access Control',
    desc: 'Admins have full control. Faculty can monitor but not control. Only @dnsc.edu.ph accounts are allowed.',
    color: '#E8F5EC',
    accent: '#2E9E52',
    icon: 'users',
    illustration: 'roles',
  },
];

const SlideIllustration = ({ type, accent, isActive = false }) => {
  const illustrations = {
    dashboard: (
      <svg width="100%" height="100%" viewBox="0 0 320 200" fill="none">
        <rect width="320" height="200" fill={accent + '12'} />
        <rect x="20" y="20" width="280" height="120" rx="12" fill="white" stroke={accent + '30'} />
        <text x="32" y="44" fontSize="11" fontWeight="700" fill={accent}>Total Energy</text>
        <text x="32" y="72" fontSize="26" fontWeight="800" fill={accent}>247.3</text>
        <text x="122" y="72" textAnchor="middle" fontSize="11" fontWeight="600" fill={accent + '80'}>kWh</text>
        <line x1="160" y1="122" x2="302" y2="122" stroke={accent + '30'} strokeWidth="1.5" />
        {[0,1,2,3,4,5,6,7].map(i => {
          const heights = [28,44,32,58,40,50,36,47];
          const baseY = 122;
          return <rect key={i} x={162 + i * 17} y={baseY - heights[i]} width="11" height={heights[i]} rx="4" fill={i === 3 ? accent : accent + '40'} />;
        })}
        <rect x="20" y="152" width="85" height="32" rx="10" fill={accent + '15'} />
        <text x="62.5" y="173" textAnchor="middle" fontSize="10" fontWeight="600" fill={accent}>₱ 2,844</text>
        <rect x="118" y="152" width="85" height="32" rx="10" fill={accent + '15'} />
        <text x="160.5" y="173" textAnchor="middle" fontSize="10" fontWeight="600" fill={accent}>18 Assigned</text>
        <rect x="216" y="152" width="85" height="32" rx="10" fill={accent + '15'} />
        <text x="258.5" y="173" textAnchor="middle" fontSize="10" fontWeight="600" fill={accent}>6 Unassigned</text>
      </svg>
    ),
    map: (
      <svg width="100%" height="100%" viewBox="0 0 320 200" fill="none">
        <rect width="320" height="200" fill={accent + '10'} />
        <image href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='320' height='200'%3E%3Crect width='320' height='200' fill='%23e8f5ec'/%3E%3C/svg%3E" width="320" height="200" />
        {/* Fake map grid */}
        {[0,1,2,3,4,5].map(i => <line key={'h'+i} x1="0" y1={i*33} x2="320" y2={i*33} stroke={accent + '15'} strokeWidth="1" />)}
        {[0,1,2,3,4,5,6,7,8,9].map(i => <line key={'v'+i} x1={i*35} y1="0" x2={i*35} y2="200" stroke={accent + '15'} strokeWidth="1" />)}
        {/* Hotspots */}
        <rect x="110" y="55" width="60" height="30" rx="6" fill="#2E9E5240" stroke="#2E9E52" strokeWidth="2" />
        <text x="140" y="75" textAnchor="middle" fontSize="9" fontWeight="700" fill="#1A5C35">IC</text>
        <rect x="185" y="75" width="80" height="55" rx="6" fill="#E8922A40" stroke="#E8922A" strokeWidth="2" />
        <text x="225" y="107" textAnchor="middle" fontSize="9" fontWeight="700" fill="#C47018">ILEGG</text>
        <rect x="225" y="15" width="70" height="35" rx="6" fill="#2E9E5240" stroke="#2E9E52" strokeWidth="2" />
        <text x="260" y="37" textAnchor="middle" fontSize="9" fontWeight="700" fill="#1A5C35">ITED</text>
        <rect x="185" y="155" width="90" height="28" rx="6" fill="#2E9E5240" stroke="#2E9E52" strokeWidth="2" />
        <text x="230" y="173" textAnchor="middle" fontSize="9" fontWeight="700" fill="#1A5C35">IAAS</text>
        <rect x="20" y="130" width="120" height="28" rx="6" fill="#2E9E5240" stroke="#2E9E52" strokeWidth="2" />
        <text x="80" y="148" textAnchor="middle" fontSize="9" fontWeight="700" fill="#1A5C35">ADMIN</text>
      </svg>
    ),
    schedule: (
      <svg width="100%" height="100%" viewBox="0 0 320 200" fill="none">
        <rect width="320" height="200" fill={accent + '10'} />
        <rect x="20" y="20" width="280" height="160" rx="12" fill="white" stroke={accent + '20'} />
        <text x="32" y="44" fontFamily="Syne, sans-serif" fontSize="11" fontWeight="700" fill={accent}>Automation Schedules</text>
        {[
          { label: 'Turn off Lights',  scope: 'Global',   time: '22:00', days: 'Mon–Fri', color: '#2E9E52' },
          { label: 'AC off at noon',   scope: 'IC',       time: '12:00', days: 'Weekdays', color: '#1A5C35' },
          { label: 'Outlets on 7AM',   scope: 'ADMIN',    time: '07:00', days: 'Daily',   color: '#2E9E52' },
        ].map((s, i) => (
          <g key={i}>
            <rect x="24" y={60 + i * 38} width="272" height="30" rx="8" fill={s.color + '12'} />
            <rect x="28" y={64 + i * 38} width="3" height="22" rx="1.5" fill={s.color} />
            <text x="38" y={78 + i * 38} fontSize="10" fontWeight="600" fill="#0F1F14">{s.label}</text>
            <text x="38" y={90 + i * 38} fontSize="8" fill="#6B8F74">{s.scope} · {s.days}</text>
            <rect x="224" y={66 + i * 38} width="68" height="18" rx="9" fill={s.color} />
            <text x="258" y={79 + i * 38} textAnchor="middle" fontSize="9" fontWeight="700" fill="white">{s.time}</text>
          </g>
        ))}
      </svg>
    ),
    analytics: (
      <svg width="100%" height="100%" viewBox="0 0 320 200" fill="none">
        <rect width="320" height="200" fill={accent + '10'} />
        <rect x="20" y="20" width="280" height="120" rx="12" fill="white" stroke={accent + '20'} />
        <text x="32" y="44" fontFamily="Syne, sans-serif" fontSize="11" fontWeight="700" fill={accent}>Consumption Trend</text>
        <polyline
          className={`trend-line ${isActive ? 'is-active' : ''}`}
          points="30,110 62,90 94,100 126,70 158,85 190,65 222,75 254,55 286,60"
          fill="none" stroke={accent} strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"
          style={{ strokeDasharray: 300, strokeDashoffset: 300 }}
        />
        <polyline
          points="30,110 62,90 94,100 126,70 158,85 190,65 222,75 254,55 286,60 286,130 30,130"
          fill={accent + '15'} stroke="none"
        />
        {[30,62,94,126,158,190,222,254,286].map((x, i) => {
          const ys = [110,90,100,70,85,65,75,55,60];
          return <circle key={i} cx={x} cy={ys[i]} r="3.5" fill={accent} stroke="white" strokeWidth="1.5" />;
        })}
        {/* CSV export button */}
        <rect x="20" y="152" width="130" height="32" rx="10" fill={accent} />
        <text x="85" y="172" textAnchor="middle" fontSize="10" fontWeight="600" fill="white">Export as CSV ↓</text>
        <rect x="162" y="152" width="138" height="32" rx="10" fill={accent + '15'} />
        <text x="231" y="172" textAnchor="middle" fontSize="10" fontWeight="600" fill={accent}>View Full History</text>
      </svg>
    ),
    device: (
      <svg width="100%" height="100%" viewBox="0 0 320 200" fill="none">
        <rect width="320" height="200" fill={accent + '10'} />
        <rect x="20" y="20" width="160" height="160" rx="16" fill="white" stroke={accent + '20'} />
        <text x="100" y="50" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="10" fontWeight="700" fill={accent}>DEV-2024-A3F7</text>
        <circle cx="100" cy="100" r="32" fill={accent + '15'} stroke={accent} strokeWidth="2" />
        <text x="100" y="96" textAnchor="middle" fontSize="8" fill={accent + '80'}>ESP32</text>
        <text x="100" y="108" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="11" fontWeight="700" fill={accent}>Lights</text>
        <rect x="32" y="145" width="136" height="22" rx="8" fill={accent} />
        <text x="100" y="160" textAnchor="middle" fontSize="9" fontWeight="600" fill="white">RELAY ON ●</text>
        {/* Right panel */}
        <rect x="192" y="20" width="108" height="60" rx="12" fill="white" stroke={accent + '20'} />
        <text x="246" y="42" textAnchor="middle" fontSize="8" fill="#6B8F74">Voltage</text>
        <text x="246" y="58" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="14" fontWeight="800" fill={accent}>220V</text>
        <rect x="192" y="92" width="108" height="60" rx="12" fill="white" stroke={accent + '20'} />
        <text x="246" y="114" textAnchor="middle" fontSize="8" fill="#6B8F74">Power</text>
        <text x="246" y="130" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="14" fontWeight="800" fill={accent}>1.2kW</text>
        <rect x="192" y="164" width="108" height="36" rx="12" fill="white" stroke={accent + '20'} />
        <circle cx="208" cy="182" r="4" fill="#2E9E52" />
        <text x="220" y="186" fontSize="9" fontWeight="600" fill="#0F1F14">Online</text>
      </svg>
    ),
    roles: (
      <svg width="100%" height="100%" viewBox="0 0 320 200" fill="none">
        <rect width="320" height="200" fill={accent + '10'} />
        {/* Admin card */}
        <rect x="20" y="20" width="132" height="160" rx="16" fill="white" stroke={accent} strokeWidth="1.5" />
        <rect x="20" y="20" width="132" height="50" rx="16" fill={accent} />
        <rect x="20" y="50" width="132" height="20" rx="0" fill={accent} />
        <text x="86" y="50" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="13" fontWeight="800" fill="white">ADMIN</text>
        <text x="86" y="65" textAnchor="middle" fontSize="9" fill="rgba(194,237,208,0.8)">Full Access</text>
        {['Relay Control','Manage Users','Settings','Analytics','Campus Map','Automation'].map((f, i) => (
          <g key={i}>
            <circle cx="36" cy={88 + i*15} r="4" fill="#2E9E52" />
            <text x="46" y={92 + i*15} fontSize="9" fill="#0F1F14">{f}</text>
          </g>
        ))}
        {/* Faculty card */}
        <rect x="168" y="20" width="132" height="160" rx="16" fill="white" stroke={accent + '40'} strokeWidth="1.5" />
        <rect x="168" y="20" width="132" height="50" rx="16" fill={accent + '20'} />
        <rect x="168" y="50" width="132" height="20" rx="0" fill={accent + '20'} />
        <text x="234" y="50" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="13" fontWeight="800" fill={accent}>FACULTY</text>
        <text x="234" y="65" textAnchor="middle" fontSize="9" fill={accent + '80'}>View Only</text>
        {['Monitor Energy','View History','Campus Map','Analytics','—','—'].map((f, i) => (
          <g key={i}>
            <circle cx="184" cy={88 + i*15} r="4" fill={f === '—' ? '#ddd' : '#2E9E52'} />
            <text x="194" y={92 + i*15} fontSize="9" fill={f === '—' ? '#ccc' : '#0F1F14'}>{f}</text>
          </g>
        ))}
      </svg>
    ),
  };
  return illustrations[type] || illustrations['dashboard'];
};

const Carousel = () => {
  const trackWrapperRef = useRef(null);
  const [virtualIndex, setVirtualIndex] = useState(slides.length);
  const [withTransition, setWithTransition] = useState(true);
  const getCardsPerView = width => (width < 900 ? 1 : width < 1280 ? 2 : 3);
  const [cardsPerView, setCardsPerView] = useState(getCardsPerView(window.innerWidth));
  const [cardWidth, setCardWidth] = useState(320);
  const [stepWidth, setStepWidth] = useState(336);

  useEffect(() => {
    const handleResize = () => {
      const nextCardsPerView = getCardsPerView(window.innerWidth);
      setCardsPerView(nextCardsPerView);

      if (!trackWrapperRef.current) return;
      const wrapperWidth = trackWrapperRef.current.clientWidth;
      const sidePadding = window.innerWidth <= 600 ? 40 : window.innerWidth <= 900 ? 48 : 80;
      const gap = 16;
      const nextCardWidth = Math.max(220, (wrapperWidth - sidePadding - gap * (nextCardsPerView - 1)) / nextCardsPerView);
      setCardWidth(nextCardWidth);
      setStepWidth(nextCardWidth + gap);
    };

    handleResize();
    const observer = new ResizeObserver(handleResize);
    if (trackWrapperRef.current) observer.observe(trackWrapperRef.current);
    window.addEventListener('resize', handleResize);
    return () => {
      observer.disconnect();
      window.removeEventListener('resize', handleResize);
    };
  }, []);

  useEffect(() => {
    const timer = window.setInterval(() => {
      setVirtualIndex(v => v + 1);
    }, 4500);
    return () => window.clearInterval(timer);
  }, []);

  const focusedPos = cardsPerView === 1 ? 0 : 1;
  const normalizeIndex = i => ((i % slides.length) + slides.length) % slides.length;
  const activeDot = normalizeIndex(virtualIndex);

  const prev = () => setVirtualIndex(v => v - 1);
  const next = () => setVirtualIndex(v => v + 1);

  const repeatedSlides = [...slides, ...slides, ...slides];

  const handleTrackTransitionEnd = () => {
    if (virtualIndex >= slides.length * 2 || virtualIndex < slides.length) {
      setWithTransition(false);
      setVirtualIndex(v => (v >= slides.length * 2 ? v - slides.length : v + slides.length));
      requestAnimationFrame(() => requestAnimationFrame(() => setWithTransition(true)));
    }
  };

  return (
    <div className="carousel-section">
      <div className="carousel-header reveal">
        <div className="section-tag">Screens & Features</div>
        <h2 className="section-title">Everything in One App</h2>
        <p className="section-desc">A complete energy management solution built for DNSC campus operations.</p>
      </div>
      <div className="carousel-track-wrapper" ref={trackWrapperRef}>
        <div
          className="carousel-track"
          style={{
            '--card-width': `${cardWidth}px`,
            '--slide-gap': '16px',
            transform: `translateX(${-(virtualIndex - focusedPos) * stepWidth}px)`,
            transition: withTransition && stepWidth > 0 ? 'transform 650ms cubic-bezier(.22,.61,.36,1)' : 'none',
          }}
          onTransitionEnd={handleTrackTransitionEnd}
        >
          {repeatedSlides.map((slide, i) => {
            const distance = Math.abs(i - virtualIndex);
            const isFocused = distance === 0;
            const isNear = distance === 1;
            return (
              <div
                key={`${slide.title}-${i}`}
                className={`carousel-slide ${isFocused ? 'is-focused' : isNear ? 'is-near' : 'is-far'}`}
              >
                <div className="slide-img" style={{ background: slide.color }}>
                  <SlideIllustration type={slide.illustration} accent={slide.accent} isActive={isFocused} />
                </div>
                <div className="slide-content">
                  <div className="slide-tag">{slide.tag}</div>
                  <div className="slide-title">{slide.title}</div>
                  <div className="slide-desc">{slide.desc}</div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
      <div className="carousel-controls">
        <button className="carousel-btn" onClick={prev}><Icon name="chevronL" size={18} /></button>
        <div className="carousel-dots">
          {slides.map((_, i) => (
            <div key={i} className={`carousel-dot ${i === activeDot ? 'active' : ''}`} onClick={() => setVirtualIndex(slides.length + i)} />
          ))}
        </div>
        <button className="carousel-btn" onClick={next}><Icon name="chevronR" size={18} /></button>
      </div>
    </div>
  );
};

// ── Main App ──────────────────────────────────────────────────────────────────
const App = () => {
  const [navScrolled, setNavScrolled] = useState(false);

  useEffect(() => {
    const handleScroll = () => setNavScrolled(window.scrollY > 40);
    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll);
  }, []);

  // Scroll reveal
  useEffect(() => {
    const observer = new IntersectionObserver(
      entries => entries.forEach(e => { if (e.isIntersecting) e.target.classList.add('visible'); }),
      { threshold: 0.12 }
    );
    document.querySelectorAll('.reveal').forEach(el => observer.observe(el));
    return () => observer.disconnect();
  }, []);

  const features = [
    { icon: 'zap',      color: '#EBF7EF', iconColor: '#1A5C35', title: 'Real-Time Monitoring',    desc: 'Live kWh, voltage, current, and power readings from each ESP32 device across all campus buildings.' },
    { icon: 'map',      color: '#E8F5EC', iconColor: '#2E9E52', title: 'Interactive Campus Map',   desc: 'Color-coded building hotspots reflect live energy levels. Admin can drag and resize zones directly on the map.' },
    { icon: 'schedule', color: '#EBF7EF', iconColor: '#1A5C35', title: 'Smart Automation',         desc: 'Schedule relay toggles globally, per building, utility type, or specific device. Executed by the ESP32 on time.' },
    { icon: 'chart',    color: '#E8F5EC', iconColor: '#2E9E52', title: 'Energy Analytics',         desc: 'Daily to yearly charts with top consuming buildings and utilities. Export detailed CSV reports anytime.' },
    { icon: 'users',    color: '#EBF7EF', iconColor: '#1A5C35', title: 'Role-Based Access',        desc: 'Admin and Faculty roles with distinct capabilities. Only @dnsc.edu.ph email accounts are permitted.' },
    { icon: 'cpu',      color: '#E8F5EC', iconColor: '#2E9E52', title: 'ESP32 Hardware Control',   desc: 'Each device runs an ESP32 with PZEM-004T for energy metering and relays/contactors for switching.' },
  ];

  const buildings = [
    { code: 'IC',    name: 'Institute of Computing',                    floors: '2 Floors' },
    { code: 'ILEGG', name: 'Institute of Leadership & Good Governance', floors: '2 Floors' },
    { code: 'ITED',  name: 'Institute of Teachers Education',           floors: '2 Floors' },
    { code: 'IAAS',  name: 'Institute of Aquatic Science',              floors: '1 Floor'  },
    { code: 'ADMIN', name: 'Administrator Building',                    floors: '1 Floor'  },
  ];

  const steps = [
    { n: '01', title: 'Device Registered',   desc: 'Each ESP32 is assigned a unique Device ID and registered in the system by the admin.' },
    { n: '02', title: 'Assigned to Room',     desc: 'Admin assigns the device to a specific building, floor, room, and utility type.' },
    { n: '03', title: 'Reads Live Data',      desc: 'ESP32 + PZEM-004T continuously reads voltage, current, power, and kWh, syncing to Firebase.' },
    { n: '04', title: 'Controlled Remotely',  desc: 'Admin toggles relays from the app or via automated schedules. Faculty monitors in read-only mode.' },
  ];

  return (
    <>
      {/* Nav */}
      <nav className={navScrolled ? 'scrolled' : ''}>
        <a className="nav-logo" href="#">
          <div className="nav-logo-icon">
            <Icon name="bolt" size={18} color="white" />
          </div>
          <span className="nav-logo-text">Smart<span>Power</span>Switch</span>
        </a>
        <a className="nav-cta" href="https://smartpowerswitch-e90d0.web.app" target="_blank">
          Launch App <Icon name="arrowRight" size={14} />
        </a>
      </nav>

      {/* Hero */}
      <div className="hero">
        <div className="hero-bg" />
        <div className="hero-grid" />
        <div className="hero-content">
          <div>
            <div className="hero-badge animate-fadeup delay-1">DNSC Campus Energy System</div>
            <h1 className="hero-title animate-fadeup delay-2">
              Smart Energy<br/>Control for<br/><span className="accent">DNSC Campus</span>
            </h1>
            <p className="hero-desc animate-fadeup delay-3">
              A real-time IoT energy monitoring and control system for Davao del Norte State College. Monitor consumption, control devices, and automate schedules — all from one app.
            </p>
            <div className="hero-actions animate-fadeup delay-4">
              <a className="btn-primary" href="https://smartpowerswitch-e90d0.web.app" target="_blank">
                Open System <Icon name="arrowRight" size={16} />
              </a>
              <a className="btn-secondary" href="#features">
                Learn More
              </a>
            </div>
          </div>
          <div className="hero-visual animate-fadeup delay-3">
            <PhoneMockup />
            {/* Floating badges */}
            <div className="float-badge float-badge-left">
              <div className="float-badge-icon" style={{ background: '#EBF7EF' }}>
                <Icon name="zap" size={18} color="#1A5C35" />
              </div>
              <div>
                <div className="float-badge-text">247.3 kWh</div>
                <div className="float-badge-sub">Total today</div>
              </div>
            </div>
            <div className="float-badge float-badge-right">
              <div className="float-badge-icon" style={{ background: '#E8F5EC' }}>
                <Icon name="checkCircle" size={18} color="#2E9E52" />
              </div>
              <div>
                <div className="float-badge-text">18 Online</div>
                <div className="float-badge-sub">ESP32 devices</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Energy crisis solution message */}
      <section className="crisis-banner reveal" aria-label="Energy Crisis Solution Message">
        <div className="crisis-layout">
          <div className="crisis-content">
            <p className="crisis-kicker">Campus Energy Transition</p>
            <h2 className="crisis-title">From Energy Crisis to Energy Intelligence</h2>
            <p className="crisis-copy">
              SmartPowerSwitch turns fragmented power usage into coordinated, data-driven action, reducing waste,
              flattening peak demand, and building a more resilient campus grid.
            </p>
          </div>
          <div className="crisis-qr" aria-label="Download App QR">
            <img
              className="crisis-qr-img"
              src="https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=https%3A%2F%2Fwww.mediafire.com%2Ffile%2Fppszpagybcuhe0w%2Fapp-release.apk%2Ffile"
              alt="QR code to download app APK"
              loading="lazy"
            />
            <p className="crisis-qr-caption">Scan to download APK</p>
          </div>
        </div>
      </section>

      {/* Features */}
      <section id="features">
        <div className="reveal">
          <div className="section-tag">What It Does</div>
          <h2 className="section-title">Built for Campus Energy Management</h2>
          <p className="section-desc">Every feature is designed around DNSC's actual infrastructure — 5 buildings, multiple rooms, and 3 types of electrical utilities.</p>
        </div>
        <div className="features-grid">
          {features.map((f, i) => (
            <div key={i} className="feature-card reveal" style={{ transitionDelay: `${i * 0.08}s` }}>
              <div className="feature-icon" style={{ background: f.color }}>
                <Icon name={f.icon} size={24} color={f.iconColor} />
              </div>
              <div className="feature-title">{f.title}</div>
              <div className="feature-desc">{f.desc}</div>
            </div>
          ))}
        </div>
      </section>

      {/* Carousel */}
      <Carousel />

      {/* How it works */}
      <div className="how-section">
        <div className="how-inner">
          <div className="reveal">
            <div className="section-tag">How It Works</div>
            <h2 className="section-title">From Device to Dashboard</h2>
            <p className="section-desc">The full loop from physical hardware to cloud-synced app in four steps.</p>
          </div>
          <div className="steps-grid">
            {steps.map((s, i) => (
              <div key={i} className="step-card reveal" style={{ transitionDelay: `${i * 0.12}s` }}>
                <div className="step-number">{s.n}</div>
                <div className="step-title">{s.title}</div>
                <div className="step-desc">{s.desc}</div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Buildings */}
      <section>
        <div className="reveal">
          <div className="section-tag">Coverage</div>
          <h2 className="section-title">5 Buildings Monitored</h2>
          <p className="section-desc">All monitored buildings are part of DNSC's main campus. Hover each card to explore.</p>
        </div>
        <div className="buildings-grid">
          {buildings.map((b, i) => (
            <div key={i} className="building-card reveal" style={{ transitionDelay: `${i * 0.08}s` }}>
              <div className="bc-code">{b.code}</div>
              <div className="bc-name">{b.name}</div>
              <div className="bc-floors">{b.floors}</div>
            </div>
          ))}
        </div>
      </section>

      {/* Hardware section */}
      <section className="hardware-section">
        <div className="reveal hardware-grid">
          <div>
            <div className="section-tag">Hardware Stack</div>
            <h2 className="section-title">Powered by ESP32</h2>
            <p className="section-desc" style={{ marginBottom: '28px' }}>
              Each utility — Lights, Outlets, and AC — is controlled by a dedicated ESP32 microcontroller paired with an energy meter and switching component.
            </p>
            {[
              { icon: 'cpu',      label: 'ESP32',        desc: 'Main controller with Wi-Fi, syncs to Firebase' },
              { icon: 'zap',      label: 'PZEM-004T',    desc: 'Energy meter — reads V, A, W, kWh' },
              { icon: 'bolt',     label: 'Relay / Contactor', desc: '220V switching for Lights, Outlets & AC' },
              { icon: 'wifi',     label: 'Firebase RTDB', desc: 'Real-time cloud sync for all readings' },
            ].map((h, i) => (
              <div key={i} className="hardware-item">
                <div className="hardware-item-icon">
                  <Icon name={h.icon} size={18} color="var(--green-dark)" />
                </div>
                <div>
                  <div className="hardware-item-title">{h.label}</div>
                  <div className="hardware-item-desc">{h.desc}</div>
                </div>
              </div>
            ))}
          </div>
          <div className="hardware-visual">
            <svg width="100%" viewBox="0 0 340 300" fill="none">
              {/* ESP32 box */}
              <rect x="110" y="100" width="120" height="80" rx="14" fill="#1A5C35" />
              <text x="170" y="135" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="11" fontWeight="800" fill="white">ESP32</text>
              <text x="170" y="152" textAnchor="middle" fontSize="9" fill="rgba(194,237,208,0.7)">Controller</text>
              {/* Wi-Fi waves */}
              <path d="M155 95 Q170 85 185 95" stroke="#6ECB8A" strokeWidth="2" fill="none" strokeLinecap="round" />
              <path d="M148 89 Q170 75 192 89" stroke="#6ECB8A" strokeWidth="1.5" fill="none" strokeLinecap="round" opacity="0.6" />
              {/* PZEM */}
              <rect x="10" y="120" width="90" height="50" rx="12" fill="#2E9E52" />
              <text x="55" y="143" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="9" fontWeight="700" fill="white">PZEM-004T</text>
              <text x="55" y="158" textAnchor="middle" fontSize="8" fill="rgba(194,237,208,0.8)">Energy Meter</text>
              {/* Firebase */}
              <rect x="240" y="120" width="90" height="50" rx="12" fill="#EBF7EF" stroke="#2E9E52" strokeWidth="1.5" />
              <text x="285" y="143" textAnchor="middle" fontFamily="Syne, sans-serif" fontSize="9" fontWeight="700" fill="#1A5C35">Firebase</text>
              <text x="285" y="158" textAnchor="middle" fontSize="8" fill="#6B8F74">Realtime DB</text>
              {/* Relay */}
              <rect x="110" y="210" width="55" height="48" rx="10" fill="#C2EDD0" stroke="#2E9E52" strokeWidth="1.5" />
              <text x="137" y="232" textAnchor="middle" fontSize="9" fontWeight="700" fill="#1A5C35">Relay</text>
              <text x="137" y="248" textAnchor="middle" fontSize="7" fill="#6B8F74">220V</text>
              {/* Contactor */}
              <rect x="175" y="210" width="55" height="48" rx="10" fill="#C2EDD0" stroke="#2E9E52" strokeWidth="1.5" />
              <text x="202" y="232" textAnchor="middle" fontSize="9" fontWeight="700" fill="#1A5C35">Contactor</text>
              <text x="202" y="248" textAnchor="middle" fontSize="7" fill="#6B8F74">AC 220V</text>
              {/* Connection lines */}
              <line x1="100" y1="145" x2="110" y2="145" stroke="#6ECB8A" strokeWidth="1.5" strokeDasharray="4 3" />
              <line x1="230" y1="145" x2="240" y2="145" stroke="#6ECB8A" strokeWidth="1.5" strokeDasharray="4 3" />
              <line x1="150" y1="180" x2="142" y2="210" stroke="#6ECB8A" strokeWidth="1.5" strokeDasharray="4 3" />
              <line x1="190" y1="180" x2="200" y2="210" stroke="#6ECB8A" strokeWidth="1.5" strokeDasharray="4 3" />
            </svg>
          </div>
        </div>
      </section>

      {/* CTA */}
      <div className="cta-section" style={{ marginTop: '80px' }}>
        <div className="cta-inner reveal">
          <div className="section-tag" style={{ justifyContent: 'center', color: 'var(--green-light)' }}>
            <span style={{ background: 'var(--green-light)', height: '2px', width: '20px', display: 'inline-block', borderRadius: '1px' }} />
            Ready to Use
          </div>
          <h2 className="cta-title">Energy Management, Simplified.</h2>
          <p className="cta-desc">
            Access the SmartPowerSwitch system with your DNSC account. Monitor your campus, automate your schedules, and take control of energy usage today.
          </p>
          <a className="cta-btn" href="https://smartpowerswitch-e90d0.web.app" target="_blank">
            Launch the App <Icon name="arrowRight" size={16} color="var(--green-dark)" />
          </a>
        </div>
      </div>

      {/* Footer */}
      <footer>
        <div className="footer-inner">
          <div className="footer-logo">
            <div className="footer-logo-icon">
              <Icon name="bolt" size={16} color="white" />
            </div>
            <div>
              <div style={{ fontFamily: 'Syne, sans-serif', fontWeight: 700, fontSize: '14px', color: 'rgba(194,237,208,0.8)' }}>SmartPowerSwitch</div>
              <div className="footer-text">DNSC Campus Energy Control System</div>
            </div>
          </div>
          <div style={{ display: 'flex', gap: '8px' }}>
            {['IC', 'ILEGG', 'ITED', 'IAAS', 'ADMIN'].map(b => (
              <div key={b} style={{ width: '32px', height: '32px', borderRadius: '8px', background: 'rgba(194,237,208,0.08)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <span style={{ fontSize: '7px', fontFamily: 'Syne, sans-serif', fontWeight: 700, color: 'rgba(194,237,208,0.5)' }}>{b}</span>
              </div>
            ))}
          </div>
        </div>
        <hr className="footer-divider" style={{ maxWidth: '1200px', margin: '28px auto 24px', borderTop: '1px solid rgba(255,255,255,0.06)' }} />
        <div className="footer-bottom">
          <div className="footer-copy">© 2024 SmartPowerSwitch · Davao del Norte State College</div>
          <div className="footer-dnsc">
            <Icon name="leaf" size={12} color="rgba(194,237,208,0.45)" />
            Built for DNSC · Davao del Norte, Philippines
          </div>
        </div>
      </footer>
    </>
  );
};

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);

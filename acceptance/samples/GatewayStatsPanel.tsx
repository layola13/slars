import {
  Accordion,
  AccordionDetails,
  AccordionSummary,
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogContent,
  DialogTitle,
  FormControl,
  Grid,
  InputLabel,
  LinearProgress,
  MenuItem,
  Paper,
  Select,
  Stack,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Tabs,
  TextField,
  ToggleButton,
  ToggleButtonGroup,
  Typography
} from "@mui/material";
import BarChartIcon from "@mui/icons-material/BarChart";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import RefreshIcon from "@mui/icons-material/Refresh";
import ReceiptLongIcon from "@mui/icons-material/ReceiptLong";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { AuthUser } from "@codex-ui/shared";
import type { TranslateFn } from "../i18n";
import {
  fetchGatewayAnalyticsDaily,
  fetchGatewayAnalyticsDimension,
  fetchGatewayAnalyticsOverview,
  fetchGatewayBy,
  fetchGatewayByStatus,
  fetchGatewayHealth,
  fetchGatewayOverview,
  fetchGatewayPerformance,
  fetchGatewayRequests,
  fetchGatewayTokensBy,
  fetchGatewayTokensDaily,
  fetchGatewayTokensSummary,
  type AnalyticsDailyRow,
  type AnalyticsDimensionRow,
  type AnalyticsOverview,
  type GatewayDailyCount,
  type GatewayDimensionRow,
  type GatewayHealthRow,
  type GatewayOverview,
  type GatewayPerformanceRow,
  type GatewayRequestRecord,
  type GatewayStatusRow,
  type UsageTokenDaily,
  type UsageTokenDimensionRow,
  type UsageTokenSummary
} from "../state/codexClient";
import {
  DailyComboChart,
  formatCount,
  formatMoney,
  RANGE_DAYS,
  RangeTabs,
  RankLegend,
  ReqCostBars,
  TokenGroupedBars,
  type RangeKey
} from "./GatewayCharts";

type Props = {
  token: string;
  currentUser: AuthUser | null;
  members?: AuthUser[];
  t: TranslateFn;
};

/**
 * 网关统计（对标 axonhub 数据看板 + 请求页的 count 层）：
 * 看板：KPI 卡、按天请求 bars、按维度 TopN；
 * 请求：过滤 + 游标分页 + 行详情。
 * token/费用仍在“使用与额度”页（request_usage_ledger）。
 */
export function GatewayStatsPanel({ token, currentUser, members = [], t }: Props) {
  const isAdmin = currentUser?.role === "admin";
  const [tab, setTab] = useState<"dashboard" | "requests" | "analytics">("dashboard");
  return (
    <Stack spacing={2.5}>
      <Stack direction="row" spacing={1} alignItems="center">
        <BarChartIcon color="primary" />
        <Box>
          <Typography variant="h5" sx={{ fontWeight: 900 }}>
            {t("settings.gateway.title")}
          </Typography>
          <Typography color="text.secondary">{t("settings.gateway.subtitle")}</Typography>
        </Box>
      </Stack>
      <Tabs value={tab} onChange={(_, value) => setTab(value)}>
        <Tab value="dashboard" label={t("settings.gateway.tabs.dashboard")} />
        <Tab value="requests" label={t("settings.gateway.tabs.requests")} />
        <Tab value="analytics" label="analytics" />
      </Tabs>
      {tab === "dashboard" ? (
        <DashboardView token={token} isAdmin={isAdmin} currentUser={currentUser} members={members} t={t} />
      ) : tab === "requests" ? (
        <RequestsView token={token} isAdmin={isAdmin} members={members} t={t} />
      ) : (
        <AnalyticsView token={token} isAdmin={isAdmin} members={members} t={t} />
      )}
    </Stack>
  );
}

function useUserFilter(isAdmin: boolean) {
  const [filterUserId, setFilterUserId] = useState("");
  const userId = isAdmin && filterUserId ? filterUserId : undefined;
  return { filterUserId, setFilterUserId, userId };
}

function UserFilterControl({ isAdmin, members, value, onChange, t }: {
  isAdmin: boolean; members: AuthUser[]; value: string; onChange: (v: string) => void; t: TranslateFn;
}) {
  if (!isAdmin) return null;
  return (
    <FormControl size="small" sx={{ minWidth: 160 }}>
      <InputLabel>{t("settings.gateway.user")}</InputLabel>
      <Select value={value} label={t("settings.gateway.user")} onChange={(e) => onChange(e.target.value)}>
        <MenuItem value="">{t("settings.gateway.allUsers")}</MenuItem>
        {members.map((m) => (
          <MenuItem key={m.id} value={m.id}>{m.email || m.id}</MenuItem>
        ))}
      </Select>
    </FormControl>
  );
}

function DashboardView({ token, isAdmin, currentUser, members, t }: { token: string; isAdmin: boolean; currentUser: AuthUser | null; members: AuthUser[]; t: TranslateFn }) {
  const [tokenRange, setTokenRange] = useState<RangeKey>("day");
  const [channelRange, setChannelRange] = useState<RangeKey>("month");
  const [modelRange, setModelRange] = useState<RangeKey>("month");
  const [memberRange, setMemberRange] = useState<RangeKey>("month");
  const [siteScope, setSiteScope] = useState<"all" | "mine">("all");
  const { filterUserId, setFilterUserId, userId: memberUserId } = useUserFilter(isAdmin);
  const meId = currentUser?.id;
  const userId = !isAdmin ? undefined : siteScope === "mine" ? meId : memberUserId;
  const [overview, setOverview] = useState<GatewayOverview | null>(null);
  const [gwDaily, setGwDaily] = useState<GatewayDailyCount[]>([]);
  const [tokenSummary, setTokenSummary] = useState<UsageTokenSummary | null>(null);
  const [tokenDaily, setTokenDaily] = useState<UsageTokenDaily[]>([]);
  const [successRows, setSuccessRows] = useState<GatewayDimensionRow[]>([]);
  const [successSort, setSuccessSort] = useState<"worst" | "best" | "most">("worst");
  const [channelReq, setChannelReq] = useState<GatewayDimensionRow[]>([]);
  const [channelTok, setChannelTok] = useState<UsageTokenDimensionRow[]>([]);
  const [modelReq, setModelReq] = useState<GatewayDimensionRow[]>([]);
  const [modelTok, setModelTok] = useState<UsageTokenDimensionRow[]>([]);
  const [memberTok, setMemberTok] = useState<UsageTokenDimensionRow[]>([]);
  const [fastModels, setFastModels] = useState<GatewayPerformanceRow[]>([]);
  const [fastProviders, setFastProviders] = useState<GatewayPerformanceRow[]>([]);
  const [statusRows, setStatusRows] = useState<GatewayStatusRow[]>([]);
  const [healthRows, setHealthRows] = useState<GatewayHealthRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [o, ts, td, success, cReq, cTok, mReq, mTok, memTok, fModels, fProviders, stRows, hRows] = await Promise.all([
        fetchGatewayOverview(token, { days: 30, userId }),
        fetchGatewayTokensSummary(token, { userId }),
        fetchGatewayTokensDaily(token, { days: 30, userId }),
        fetchGatewayBy(token, { dimension: "provider", days: 30, limit: 50, userId }),
        fetchGatewayBy(token, { dimension: "provider", days: RANGE_DAYS[channelRange], limit: 10, userId }),
        fetchGatewayTokensBy(token, { dimension: "provider", days: RANGE_DAYS[channelRange], limit: 10, userId }),
        fetchGatewayBy(token, { dimension: "model", days: RANGE_DAYS[modelRange], limit: 10, userId }),
        fetchGatewayTokensBy(token, { dimension: "model", days: RANGE_DAYS[modelRange], limit: 10, userId }),
        fetchGatewayTokensBy(token, { dimension: "owner", days: RANGE_DAYS[memberRange], limit: 10, userId }),
        fetchGatewayPerformance(token, { dimension: "model", days: 30, limit: 5, userId }).catch(() => [] as GatewayPerformanceRow[]),
        fetchGatewayPerformance(token, { dimension: "provider", days: 30, limit: 5, userId }).catch(() => [] as GatewayPerformanceRow[]),
        fetchGatewayByStatus(token, { days: 30, limit: 20, userId }).catch(() => [] as GatewayStatusRow[]),
        fetchGatewayHealth(token, { days: 7, limit: 50, userId }).catch(() => [] as GatewayHealthRow[]),
      ]);
      setOverview(o.overview);
      setGwDaily(o.daily);
      setTokenSummary(ts);
      setTokenDaily(td);
      setSuccessRows(success);
      setChannelReq(cReq);
      setChannelTok(cTok);
      setModelReq(mReq);
      setModelTok(mTok);
      setMemberTok(memTok);
      setFastModels(fModels);
      setFastProviders(fProviders);
      setStatusRows(stRows);
      setHealthRows(hRows);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [channelRange, memberRange, modelRange, token, userId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const tokenBucket = tokenSummary?.[tokenRange === "all" ? "all" : tokenRange] ?? { input: 0, output: 0, cached: 0, total: 0, cost: 0, count: 0 };
  const okCount = overview?.okCount ?? 0;
  const done = okCount + (overview?.failCount ?? 0);
  const successRate = done === 0 ? 0 : (okCount / done) * 100;
  const last14 = gwDaily.slice(-14);
  const thisWeekCount = last14.slice(-7).reduce((s, d) => s + d.count, 0);
  const lastWeekCount = last14.slice(0, 7).reduce((s, d) => s + d.count, 0);
  const wow = lastWeekCount === 0 ? (thisWeekCount > 0 ? 100 : 0) : ((thisWeekCount - lastWeekCount) / lastWeekCount) * 100;

  const comboData = useMemo(() => {
    const tokByDate = new Map(tokenDaily.map((d) => [d.date, d]));
    // gwDaily 后端已按日历补零；token 缺失日期补 0，避免面积断裂与周同比失真。
    return gwDaily.map((d) => {
      const tok = tokByDate.get(d.date);
      return { date: d.date, count: d.count, tokens: tok?.total ?? 0, cost: tok?.cost ?? 0 };
    });
  }, [gwDaily, tokenDaily]);

  const sortedSuccess = useMemo(() => {
    const rateOf = (r: GatewayDimensionRow): number => {
      const d = r.okCount + r.failCount;
      return d === 0 ? 100 : (r.okCount / d) * 100;
    };
    const rows = [...successRows];
    if (successSort === "best") rows.sort((a, b) => rateOf(b) - rateOf(a));
    else if (successSort === "most") rows.sort((a, b) => (b.okCount + b.failCount) - (a.okCount + a.failCount));
    else rows.sort((a, b) => rateOf(a) - rateOf(b));
    return rows;
  }, [successRows, successSort]);

  return (
    <Stack spacing={2}>
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
        <UserFilterControl isAdmin={isAdmin} members={members} value={filterUserId} onChange={setFilterUserId} t={t} />
        {isAdmin ? (
          <ToggleButtonGroup size="small" exclusive value={siteScope} onChange={(_, v) => v && setSiteScope(v)}>
            <ToggleButton value="all">{t("settings.gateway.scope.all")}</ToggleButton>
            <ToggleButton value="mine">{t("settings.gateway.scope.mine")}</ToggleButton>
          </ToggleButtonGroup>
        ) : null}
        <Button size="small" startIcon={<RefreshIcon />} onClick={() => void reload()}>{t("settings.gateway.refresh")}</Button>
      </Stack>
      {error ? <Alert severity="error">{error}</Alert> : null}
      {loading && !overview ? (
        <Stack direction="row" spacing={1} alignItems="center"><CircularProgress size={20} /><Typography>{t("settings.gateway.loading")}</Typography></Stack>
      ) : null}
      <Grid container spacing={1.5}>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle2" color="text.secondary">{t("settings.gateway.kpi.total")}</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>{formatCount(overview?.total ?? 0)}</Typography>
            <Typography variant="body2" sx={{ mt: 1 }} color={wow >= 0 ? "success.main" : "error.main"}>
              {wow >= 0 ? "+" : ""}{wow.toFixed(0)}% {t("settings.gateway.kpi.vsLastWeek")}
            </Typography>
            <Typography variant="caption" color="text.secondary">
              {t("settings.gateway.kpi.thisWeek", { n: String(formatCount(overview?.thisWeek ?? 0)) })} · {t("settings.gateway.kpi.thisMonth", { n: String(formatCount(overview?.thisMonth ?? 0)) })}
            </Typography>
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle2" color="text.secondary">{t("settings.gateway.kpi.successRate")}</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>{successRate.toFixed(1)}%</Typography>
            <LinearProgress variant="determinate" value={successRate} sx={{ mt: 1.5, height: 8, borderRadius: 1 }} />
            <Typography variant="caption" color="text.secondary" sx={{ mt: 1, display: "block" }}>
              {t("settings.gateway.kpi.failCount", { n: String(formatCount(overview?.failCount ?? 0)) })}
            </Typography>
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Stack direction="row" justifyContent="space-between" alignItems="center">
              <Typography variant="subtitle2" color="text.secondary">{t("settings.gateway.kpi.tokens")}</Typography>
              <RangeTabs value={tokenRange} onChange={setTokenRange} t={t} />
            </Stack>
            <Stack direction="row" spacing={2} sx={{ mt: 1.5 }}>
              <Box sx={{ flex: 1 }}>
                <Typography variant="caption" color="text.secondary">{t("settings.gateway.kpi.tokensInput")}</Typography>
                <Typography variant="h6" sx={{ fontFamily: "monospace" }}>{formatCount(tokenBucket.input)}</Typography>
              </Box>
              <Box sx={{ flex: 1 }}>
                <Typography variant="caption" color="text.secondary">{t("settings.gateway.kpi.tokensOutput")}</Typography>
                <Typography variant="h6" sx={{ fontFamily: "monospace" }}>{formatCount(tokenBucket.output)}</Typography>
              </Box>
              <Box sx={{ flex: 1 }}>
                <Typography variant="caption" color="text.secondary">{t("settings.gateway.kpi.tokensCached")}</Typography>
                <Typography variant="h6" sx={{ fontFamily: "monospace" }}>{formatCount(tokenBucket.cached)}</Typography>
              </Box>
            </Stack>
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%", bgcolor: "primary.main", color: "primary.contrastText" }}>
            <Typography variant="subtitle2" sx={{ opacity: 0.85 }}>{t("settings.gateway.kpi.today")}</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>{formatCount(overview?.today ?? 0)}</Typography>
            <Typography variant="caption" sx={{ mt: 1, display: "block", opacity: 0.85 }}>
              {t("settings.gateway.kpi.thisWeek", { n: String(formatCount(overview?.thisWeek ?? 0)) })} · {t("settings.gateway.kpi.thisMonth", { n: String(formatCount(overview?.thisMonth ?? 0)) })}
            </Typography>
          </Paper>
        </Grid>
      </Grid>
      <Grid container spacing={1.5}>
        <Grid size={{ xs: 12, md: 7 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>{t("settings.gateway.daily.title")}</Typography>
            <Stack direction="row" spacing={2} sx={{ my: 1 }}>
              <Typography variant="caption" color="text.secondary">■ {t("settings.gateway.legend.tokens")}</Typography>
              <Typography variant="caption" color="text.secondary">■ {t("settings.gateway.legend.requests")}</Typography>
              <Typography variant="caption" color="text.secondary">— {t("settings.gateway.legend.cost")}</Typography>
            </Stack>
            {comboData.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : <DailyComboChart data={comboData} />}
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, md: 5 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>{t("settings.gateway.success.title")}</Typography>
            <Typography variant="body2" color="text.secondary">{t("settings.gateway.success.desc")}</Typography>
            <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
              <ToggleButtonGroup
                size="small"
                exclusive
                value={successSort}
                onChange={(_, v) => v && setSuccessSort(v)}
              >
                <ToggleButton value="worst">worst</ToggleButton>
                <ToggleButton value="best">best</ToggleButton>
                <ToggleButton value="most">most</ToggleButton>
              </ToggleButtonGroup>
            </Stack>
            <Stack spacing={1.5} sx={{ mt: 1.5 }}>
              {sortedSuccess.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : sortedSuccess.map((r) => {
                const d = r.okCount + r.failCount;
                const rate = d === 0 ? 0 : (r.okCount / d) * 100;
                const warn = rate < 95;
                return (
                  <Stack key={r.name} direction="row" spacing={1.5} alignItems="center">
                    <Box sx={{ flex: 1, minWidth: 0 }}>
                      <Typography variant="body2" sx={{ fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis" }} title={r.name}>{r.name}</Typography>
                      <Typography variant="caption" color="text.secondary">✓ {formatCount(r.okCount)} ✗ {formatCount(r.failCount)}</Typography>
                    </Box>
                    <Typography variant="body1" sx={{ fontFamily: "monospace", fontWeight: 700 }} color={warn ? "error.main" : "text.primary"}>{rate.toFixed(1)}%</Typography>
                  </Stack>
                );
              })}
            </Stack>
          </Paper>
        </Grid>
      </Grid>
      <DimensionSection
        title={t("settings.gateway.sections.channels")}
        reqTitle={t("settings.gateway.charts.reqCost")}
        reqDesc={t("settings.gateway.charts.reqCostDesc")}
        tokTitle={t("settings.gateway.charts.tokens")}
        tokDesc={t("settings.gateway.charts.tokensDesc")}
        range={channelRange}
        onRange={setChannelRange}
        reqRows={channelReq}
        tokRows={channelTok}
        t={t}
      />
      <DimensionSection
        title={t("settings.gateway.sections.models")}
        reqTitle={t("settings.gateway.charts.reqCost")}
        reqDesc={t("settings.gateway.charts.reqCostDesc")}
        tokTitle={t("settings.gateway.charts.tokens")}
        tokDesc={t("settings.gateway.charts.tokensDesc")}
        range={modelRange}
        onRange={setModelRange}
        reqRows={modelReq}
        tokRows={modelTok}
        t={t}
      />
      <DimensionSection
        title={t("settings.gateway.sections.members")}
        reqTitle={t("settings.gateway.charts.reqCost")}
        reqDesc={t("settings.gateway.charts.reqCostDesc")}
        tokTitle={t("settings.gateway.charts.tokens")}
        tokDesc={t("settings.gateway.charts.tokensDesc")}
        range={memberRange}
        onRange={setMemberRange}
        reqRows={memberTok.map((r) => ({ name: r.name, count: r.count, okCount: r.count, failCount: 0 }))}
        tokRows={memberTok}
        t={t}
      />
      <PerformanceSection title="fastest models" rows={fastModels} t={t} />
      <PerformanceSection title="fastest providers" rows={fastProviders} t={t} />
      <StatusSection rows={statusRows} t={t} />
      <HealthSection rows={healthRows} t={t} />
    </Stack>
  );
}

function StatusSection({ rows, t }: {
  rows: GatewayStatusRow[]; t: TranslateFn;
}) {
  return (
    <Accordion defaultExpanded={false}>
      <AccordionSummary expandIcon={<ExpandMoreIcon />}>
        <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>status codes</Typography>
      </AccordionSummary>
      <AccordionDetails>
        {rows.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : (
          <Stack spacing={0.75}>
            {rows.map((r) => (
              <Stack key={r.statusCode == null ? "pending" : String(r.statusCode)} direction="row" spacing={1} alignItems="baseline">
                <Chip
                  size="small"
                  color={r.statusCode == null ? "default" : r.statusCode < 400 ? "success" : r.statusCode < 500 ? "warning" : "error"}
                  label={r.statusCode == null ? "pending" : String(r.statusCode)}
                />
                <Typography variant="body2" sx={{ flex: 1, fontFamily: "monospace" }}>
                  {formatCount(r.count)} req
                </Typography>
                <Typography variant="caption" color="text.secondary">✓ {formatCount(r.okCount)} ✗ {formatCount(r.failCount)}</Typography>
              </Stack>
            ))}
            <Typography variant="caption" color="text.secondary">
              upstream status distribution (30d); pending = no upstream response yet.
            </Typography>
          </Stack>
        )}
      </AccordionDetails>
    </Accordion>
  );
}

function HealthSection({ rows, t }: {
  rows: GatewayHealthRow[]; t: TranslateFn;
}) {
  return (
    <Accordion defaultExpanded={false}>
      <AccordionSummary expandIcon={<ExpandMoreIcon />}>
        <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>provider health</Typography>
      </AccordionSummary>
      <AccordionDetails>
        {rows.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : (
          <Stack spacing={0.75}>
            {rows.map((r) => (
              <Stack key={r.name} direction="row" spacing={1} alignItems="baseline">
                <Chip
                  size="small"
                  color={r.status === "healthy" ? "success" : r.status === "degraded" ? "warning" : r.status === "down" ? "error" : "default"}
                  variant={r.status === "unknown" ? "outlined" : "filled"}
                  label={r.status}
                />
                <Typography variant="body2" sx={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }} title={r.name}>{r.name}</Typography>
                <Typography variant="body2" sx={{ fontFamily: "monospace" }}>
                  {r.successRate.toFixed(1)}% · {formatCount(r.requestCount)}req
                </Typography>
              </Stack>
            ))}
            <Typography variant="caption" color="text.secondary">
              read-only 7d summary; auto-disable needs a feature flag (separate task).
            </Typography>
          </Stack>
        )}
      </AccordionDetails>
    </Accordion>
  );
}

function PerformanceSection({ title, rows, t }: {
  title: string; rows: GatewayPerformanceRow[]; t: TranslateFn;
}) {
  return (
    <Accordion defaultExpanded={false}>
      <AccordionSummary expandIcon={<ExpandMoreIcon />}>
        <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>{title}</Typography>
      </AccordionSummary>
      <AccordionDetails>
        {rows.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : (
          <Stack spacing={0.75}>
            {rows.map((r, i) => (
              <Stack key={r.name} direction="row" spacing={1} alignItems="baseline">
                <Typography variant="body2" color="text.secondary" sx={{ width: 32 }}>{String(i + 1).padStart(2, "0")}.</Typography>
                <Typography variant="body2" sx={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }} title={r.name}>{r.name}</Typography>
                <Chip
                  size="small"
                  color={r.confidence === "high" ? "success" : r.confidence === "medium" ? "info" : "default"}
                  variant={r.confidence === "low" ? "outlined" : "filled"}
                  label={r.confidence}
                />
                <Typography variant="body2" sx={{ fontFamily: "monospace" }}>
                  {r.throughput > 0 ? `${r.throughput}t/s` : "—"} · ttft {r.avgTtftMs}ms · p95 {r.p95LatencyMs ?? "—"}{r.p95LatencyMs != null ? "ms" : ""} · {r.requestCount}req
                </Typography>
              </Stack>
            ))}
            <Typography variant="caption" color="text.secondary">
              throughput = usage tokens / gateway latency (30d); confidence high ≥30req, medium ≥10req.
            </Typography>
          </Stack>
        )}
      </AccordionDetails>
    </Accordion>
  );
}

function DimensionSection({ title, reqTitle, reqDesc, tokTitle, tokDesc, range, onRange, reqRows, tokRows, t }: {
  title: string; reqTitle: string; reqDesc: string; tokTitle: string; tokDesc: string;
  range: RangeKey; onRange: (v: RangeKey) => void;
  reqRows: GatewayDimensionRow[]; tokRows: UsageTokenDimensionRow[]; t: TranslateFn;
}) {
  return (
    <Accordion defaultExpanded>
      <AccordionSummary expandIcon={<ExpandMoreIcon />}>
        <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>{title}</Typography>
      </AccordionSummary>
      <AccordionDetails>
        <Grid container spacing={1.5}>
          <Grid size={{ xs: 12, md: 6 }}>
            <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>{reqTitle}</Typography>
            <Typography variant="caption" color="text.secondary">{reqDesc}</Typography>
            <Box sx={{ mt: 1, mb: 1 }}><RangeTabs value={range} onChange={onRange} t={t} /></Box>
            {reqRows.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : (
              <>
                <ReqCostBars rows={reqRows.map((r) => ({ name: r.name, count: r.count, cost: 0 }))} />
                <RankLegend rows={reqRows.map((r) => ({ name: r.name, total: r.count }))} totalKey="count" />
              </>
            )}
          </Grid>
          <Grid size={{ xs: 12, md: 6 }}>
            <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>{tokTitle}</Typography>
            <Typography variant="caption" color="text.secondary">{tokDesc}</Typography>
            <Box sx={{ mt: 1, mb: 1 }}><RangeTabs value={range} onChange={onRange} t={t} /></Box>
            {tokRows.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography> : (
              <>
                <TokenGroupedBars rows={tokRows} />
                <RankLegend rows={tokRows.map((r) => ({ name: r.name, total: r.total, cost: r.cost }))} totalKey="total" />
              </>
            )}
          </Grid>
        </Grid>
      </AccordionDetails>
    </Accordion>
  );
}

const ENDPOINTS = ["", "responses", "responses/compact", "messages", "chat/completions", "jev/evaluate"];

function RequestsView({ token, isAdmin, members, t }: { token: string; isAdmin: boolean; members: AuthUser[]; t: TranslateFn }) {
  const { filterUserId, setFilterUserId, userId } = useUserFilter(isAdmin);
  const [providerId, setProviderId] = useState("");
  const [groupId, setGroupId] = useState("");
  const [model, setModel] = useState("");
  const [ok, setOk] = useState<"" | "true" | "false">("");
  const [status, setStatus] = useState("");
  const [source, setSource] = useState("");
  const [endpoint, setEndpoint] = useState("");
  const [entries, setEntries] = useState<GatewayRequestRecord[]>([]);
  const [cursorStack, setCursorStack] = useState<string[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [detail, setDetail] = useState<GatewayRequestRecord | null>(null);

  const load = useCallback(async (cursor?: string, stack?: string[]) => {
    setLoading(true);
    setError(null);
    try {
      const page = await fetchGatewayRequests(token, {
        limit: 20,
        ...(cursor ? { cursor } : {}),
        ...(providerId.trim() ? { providerId: providerId.trim() } : {}),
        ...(groupId.trim() ? { groupId: groupId.trim() } : {}),
        ...(model.trim() ? { model: model.trim() } : {}),
        // status 优先于旧 ok 布尔（保持兼容：未选五态时回退 ok）。
        ...(status ? { status } : ok === "" ? {} : { ok: ok === "true" }),
        ...(source ? { source } : {}),
        ...(endpoint ? { endpoint } : {}),
        userId,
      });
      setEntries(page.entries);
      setNextCursor(page.nextCursor);
      if (stack !== undefined) setCursorStack(stack);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [endpoint, groupId, model, ok, providerId, source, status, token, userId]);

  useEffect(() => {
    void load(undefined, []);
  }, [load]);

  return (
    <Stack spacing={2}>
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
        <UserFilterControl isAdmin={isAdmin} members={members} value={filterUserId} onChange={setFilterUserId} t={t} />
        <TextField size="small" sx={{ width: 150 }} label={t("settings.gateway.filters.provider")} value={providerId} onChange={(e) => setProviderId(e.target.value)} />
        <TextField size="small" sx={{ width: 130 }} label={t("settings.gateway.filters.group")} value={groupId} onChange={(e) => setGroupId(e.target.value)} />
        <TextField size="small" sx={{ width: 170 }} label={t("settings.gateway.filters.model")} value={model} onChange={(e) => setModel(e.target.value)} />
        <FormControl size="small" sx={{ minWidth: 110 }}>
          <InputLabel>{t("settings.gateway.filters.status")}</InputLabel>
          <Select value={ok} label={t("settings.gateway.filters.status")} onChange={(e) => setOk(e.target.value as "" | "true" | "false")}>
            <MenuItem value="">{t("settings.gateway.filters.all")}</MenuItem>
            <MenuItem value="true">{t("settings.gateway.status.ok")}</MenuItem>
            <MenuItem value="false">{t("settings.gateway.status.fail")}</MenuItem>
          </Select>
        </FormControl>
        <FormControl size="small" sx={{ minWidth: 130 }}>
          <InputLabel>state</InputLabel>
          <Select value={status} label="state" onChange={(e) => { setStatus(e.target.value); if (e.target.value) setOk(""); }}>
            <MenuItem value="">all-states</MenuItem>
            <MenuItem value="pending">pending</MenuItem>
            <MenuItem value="processing">processing</MenuItem>
            <MenuItem value="completed">completed</MenuItem>
            <MenuItem value="failed">failed</MenuItem>
            <MenuItem value="canceled">canceled</MenuItem>
          </Select>
        </FormControl>
        <FormControl size="small" sx={{ minWidth: 120 }}>
          <InputLabel>source</InputLabel>
          <Select value={source} label="source" onChange={(e) => setSource(e.target.value)}>
            <MenuItem value="">all-src</MenuItem>
            <MenuItem value="api">api</MenuItem>
            <MenuItem value="playground">playground</MenuItem>
            <MenuItem value="test">test</MenuItem>
            <MenuItem value="direct">direct</MenuItem>
          </Select>
        </FormControl>
        <FormControl size="small" sx={{ minWidth: 150 }}>
          <InputLabel>{t("settings.gateway.filters.endpoint")}</InputLabel>
          <Select value={endpoint} label={t("settings.gateway.filters.endpoint")} onChange={(e) => setEndpoint(e.target.value)}>
            {ENDPOINTS.map((e) => <MenuItem key={e} value={e}>{e || t("settings.gateway.filters.all")}</MenuItem>)}
          </Select>
        </FormControl>
        <Button size="small" startIcon={<RefreshIcon />} onClick={() => void load(undefined, [])}>{t("settings.gateway.refresh")}</Button>
      </Stack>
      {error ? <Alert severity="error">{error}</Alert> : null}
      <Paper>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>{t("settings.gateway.table.time")}</TableCell>
              <TableCell>{t("settings.gateway.table.endpoint")}</TableCell>
              <TableCell>{t("settings.gateway.table.route")}</TableCell>
              <TableCell>{t("settings.gateway.table.model")}</TableCell>
              <TableCell>src/state</TableCell>
              <TableCell align="right">{t("settings.gateway.table.status")}</TableCell>
              <TableCell align="right">ttft/latency</TableCell>
              <TableCell align="right">tokens/tok-s</TableCell>
              <TableCell align="right">cache/cost</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {entries.map((entry) => (
              <TableRow key={entry.id} hover sx={{ cursor: "pointer" }} onClick={() => setDetail(entry)}>
                <TableCell sx={{ fontFamily: "monospace", whiteSpace: "nowrap" }}>{formatTs(entry.createdAt)}</TableCell>
                <TableCell sx={{ fontFamily: "monospace" }}>{entry.endpoint}</TableCell>
                <TableCell sx={{ maxWidth: 200, overflow: "hidden", textOverflow: "ellipsis" }} title={`${entry.providerId} / ${entry.groupId}`}>
                  {entry.providerId}/{entry.groupId}
                </TableCell>
                <TableCell sx={{ maxWidth: 180, overflow: "hidden", textOverflow: "ellipsis" }} title={entry.model ?? ""}>
                  {entry.model ?? "—"}{entry.stream ? " ⚡" : ""}
                </TableCell>
                <TableCell sx={{ fontFamily: "monospace", whiteSpace: "nowrap" }}>
                  {entry.source ?? "—"}{entry.status ? `/${entry.status}` : ""}
                </TableCell>
                <TableCell align="right">
                  {entry.status === "canceled" ? <Chip size="small" color="warning" label={`canceled${entry.upstreamStatus ? ` ${entry.upstreamStatus}` : ""}`} />
                    : entry.status === "pending" ? <Chip size="small" variant="outlined" label="pending" />
                    : entry.status === "processing" ? <Chip size="small" color="info" variant="outlined" label="processing" />
                    : entry.ok === true ? <Chip size="small" color="success" label={`${t("settings.gateway.status.ok")}${entry.upstreamStatus ? ` ${entry.upstreamStatus}` : ""}`} />
                    : entry.ok === false ? <Chip size="small" color="error" label={`${t("settings.gateway.status.fail")}${entry.upstreamStatus ? ` ${entry.upstreamStatus}` : ""}`} />
                    : <Chip size="small" variant="outlined" label={t("settings.gateway.status.pending")} />}
                </TableCell>
                <TableCell align="right" sx={{ fontFamily: "monospace", whiteSpace: "nowrap" }}>
                  {entry.ttftMs != null ? `${entry.ttftMs}ms` : "—"}/{entry.latencyMs != null ? `${entry.latencyMs}ms` : "—"}
                </TableCell>
                <TableCell align="right" sx={{ fontFamily: "monospace", whiteSpace: "nowrap" }}>
                  {entry.tokens ? `${entry.tokens.total}t${entry.tokensPerSecond != null ? ` ${entry.tokensPerSecond}/s` : ""}${entry.tokens.reasoning ? ` r${entry.tokens.reasoning}` : ""}` : "—"}
                </TableCell>
                <TableCell align="right" sx={{ fontFamily: "monospace", whiteSpace: "nowrap" }}>
                  {entry.cacheHitRate != null ? `${entry.cacheHitRate}%` : "—"}{entry.costUsd != null ? ` $${entry.costUsd.toFixed(6)}` : ""}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        {entries.length === 0 && !loading ? (
          <Typography color="text.secondary" sx={{ p: 2 }}>{t("settings.gateway.empty")}</Typography>
        ) : null}
        <Stack direction="row" spacing={1} justifyContent="flex-end" sx={{ p: 1.5 }}>
          <Button
            size="small"
            disabled={loading || cursorStack.length === 0}
            onClick={() => {
              const stack = cursorStack.slice(0, -1);
              void load(stack.length === 0 ? undefined : stack[stack.length - 1], stack);
            }}
          >
            {t("settings.gateway.prev")}
          </Button>
          <Button
            size="small"
            disabled={loading || !nextCursor}
            onClick={() => nextCursor && void load(nextCursor, [...cursorStack, nextCursor])}
          >
            {t("settings.gateway.next")}
          </Button>
        </Stack>
      </Paper>
      <RequestDetailDialog token={token} entry={detail} userId={userId} onClose={() => setDetail(null)} t={t} />
    </Stack>
  );
}

/** 请求详情（对标 axonhub request-detail 子集）：概览/用量/执行链/cURL/JSON。body 不落库，故无 body/对话阅览 Tab。 */
function RequestDetailDialog({ token, entry, userId, onClose, t }: {
  token: string; entry: GatewayRequestRecord | null; userId?: string; onClose: () => void; t: TranslateFn;
}) {
  const [tab, setTab] = useState<"overview" | "usage" | "chain" | "curl" | "json">("overview");
  const [siblings, setSiblings] = useState<GatewayRequestRecord[]>([]);
  const [chainLoading, setChainLoading] = useState(false);
  useEffect(() => {
    setTab("overview");
    setSiblings([]);
    if (!entry?.threadId) return;
    let cancelled = false;
    setChainLoading(true);
    fetchGatewayRequests(token, { limit: 20, threadId: entry.threadId, userId })
      .then((page) => { if (!cancelled) setSiblings(page.entries); })
      .catch(() => { if (!cancelled) setSiblings([]); })
      .finally(() => { if (!cancelled) setChainLoading(false); });
    return () => { cancelled = true; };
  }, [entry?.id, entry?.threadId, token, userId]);
  const curlPreview = useMemo(() => {
    if (!entry) return "";
    if (entry.endpoint.startsWith("direct/")) {
      return `# ${entry.endpoint} is a direct-backend sidecar row (no upstream HTTP to replay).\n# tokens/usage for this turn live in request_usage_ledger (thread ${entry.threadId ?? "—"}).`;
    }
    const path = entry.endpoint === "jev/evaluate" ? "jev/evaluate" : `v1/${entry.endpoint}`;
    return [
      `curl -X POST "http://127.0.0.1:43121/api/relay-gateway/${entry.providerId}/${entry.groupId}/${path}" \\`,
      `  -H "Authorization: Bearer <relay-gateway-token>" \\`,
      `  -H "Content-Type: application/json" \\`,
      `  -d '{"model": "${entry.model ?? "<model>"}", "stream": ${entry.stream ? "true" : "false"}}'`,
      `# NOTE: request/response bodies are NOT stored (streaming passthrough); replay with your own body.`,
    ].join("\n");
  }, [entry]);
  const kv = (k: string, v: string): string => `${k}: ${v}`;
  return (
    <Dialog open={entry !== null} onClose={onClose} maxWidth="md" fullWidth>
      <DialogTitle>
        <Stack direction="row" spacing={1} alignItems="center">
          <ReceiptLongIcon fontSize="small" />
          <Typography variant="subtitle1" sx={{ fontFamily: "monospace" }}>{entry?.id}</Typography>
        </Stack>
      </DialogTitle>
      <DialogContent>
        <Tabs value={tab} onChange={(_, v) => setTab(v)} sx={{ mb: 1.5 }}>
          <Tab value="overview" label="overview" />
          <Tab value="usage" label="usage" />
          <Tab value="chain" label={`chain${siblings.length ? ` (${siblings.length})` : ""}`} />
          <Tab value="curl" label="curl" />
          <Tab value="json" label="json" />
        </Tabs>
        {tab === "overview" && entry ? (
          <Typography component="pre" sx={{ fontSize: 12, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
            {[
              kv("status", `${entry.source ?? "—"}/${entry.status ?? (entry.ok === true ? "completed" : entry.ok === false ? "failed" : "pending")}${entry.upstreamStatus ? ` upstream=${entry.upstreamStatus}` : ""}`),
              kv("route", `${entry.providerId}/${entry.groupId}`),
              kv("model", `${entry.model ?? "—"}${entry.stream ? " stream" : ""}`),
              kv("endpoint", entry.endpoint),
              kv("time", `${formatTs(entry.createdAt)}  ttft=${entry.ttftMs ?? "—"}ms  latency=${entry.latencyMs ?? "—"}ms`),
              kv("thread", `${entry.threadId ?? "—"}  turn=${entry.turnId ?? "—"}`),
              ...(entry.error ? [kv("error", entry.error)] : []),
            ].join("\n")}
          </Typography>
        ) : null}
        {tab === "usage" && entry ? (
          <Typography component="pre" sx={{ fontSize: 12, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
            {entry.tokens ? [
              kv("total", String(entry.tokens.total)),
              kv("input/output", `${entry.tokens.input}/${entry.tokens.output}`),
              kv("cachedRead/cacheWrite", `${entry.tokens.cachedRead}/${entry.tokens.cacheWrite}`),
              kv("reasoning", String(entry.tokens.reasoning)),
              kv("tok/s", entry.tokensPerSecond != null ? String(entry.tokensPerSecond) : "—"),
              kv("cacheHit", entry.cacheHitRate != null ? `${entry.cacheHitRate}%` : "—"),
              kv("cost", entry.costUsd != null ? `$${entry.costUsd.toFixed(6)}` : "—"),
              ...(entry.costBreakdown ? [
                kv("cost/input", `$${entry.costBreakdown.input.toFixed(6)}`),
                kv("cost/cached", `$${entry.costBreakdown.cachedInput.toFixed(6)}`),
                kv("cost/write", `$${entry.costBreakdown.cacheWrite.toFixed(6)}`),
                kv("cost/output", `$${entry.costBreakdown.output.toFixed(6)}`),
              ] : []),
            ].join("\n") : t("settings.gateway.empty")}
          </Typography>
        ) : null}
        {tab === "chain" ? (
          chainLoading ? <Typography color="text.secondary">loading…</Typography>
          : siblings.length === 0 ? <Typography color="text.secondary">{t("settings.gateway.empty")}</Typography>
          : (
            <Stack spacing={0.5}>
              {siblings.map((s) => (
                <Typography key={s.id} variant="body2" sx={{ fontFamily: "monospace", fontWeight: s.id === entry?.id ? 800 : 400 }}>
                  {s.id === entry?.id ? "▶ " : "· "}{formatTs(s.createdAt)} {s.endpoint} {s.model ?? "—"} {s.status ?? (s.ok === true ? "completed" : s.ok === false ? "failed" : "pending")} {s.latencyMs != null ? `${s.latencyMs}ms` : ""}
                </Typography>
              ))}
            </Stack>
          )
        ) : null}
        {tab === "curl" ? (
          <Typography component="pre" sx={{ fontSize: 12, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
            {curlPreview}
          </Typography>
        ) : null}
        {tab === "json" ? (
          <Typography component="pre" sx={{ fontSize: 12, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
            {entry ? JSON.stringify(entry, null, 2) : ""}
          </Typography>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

/**
 * Analytics 多维分析（对标 axonhub analytics 页子集）：
 * 起止日期 + 快捷 + provider/group/model 过滤 + 概览卡（含缓存命中率）
 * + 日趋势（复用 DailyComboChart）+ provider/model 维度明细。
 */
function AnalyticsView({ token, isAdmin, members, t }: { token: string; isAdmin: boolean; members: AuthUser[]; t: TranslateFn }) {
  const { filterUserId, setFilterUserId, userId } = useUserFilter(isAdmin);
  const todayStr = useMemo(() => {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  }, []);
  const defaultStart = useMemo(() => {
    const d = new Date(Date.now() - 29 * 24 * 60 * 60 * 1000);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  }, []);
  const [startDate, setStartDate] = useState(defaultStart);
  const [endDate, setEndDate] = useState(todayStr);
  const [providerId, setProviderId] = useState("");
  const [groupId, setGroupId] = useState("");
  const [model, setModel] = useState("");
  const [overview, setOverview] = useState<AnalyticsOverview | null>(null);
  const [daily, setDaily] = useState<AnalyticsDailyRow[]>([]);
  const [byProvider, setByProvider] = useState<AnalyticsDimensionRow[]>([]);
  const [byModel, setByModel] = useState<AnalyticsDimensionRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const applyShortcut = (days: number) => {
    const end = new Date();
    const start = new Date(Date.now() - (days - 1) * 24 * 60 * 60 * 1000);
    const fmt = (d: Date): string => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    setStartDate(fmt(start));
    setEndDate(fmt(end));
  };

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const base = {
        ...(startDate ? { startDate } : {}),
        ...(endDate ? { endDate } : {}),
        ...(providerId.trim() ? { providerId: providerId.trim() } : {}),
        ...(groupId.trim() ? { groupId: groupId.trim() } : {}),
        ...(model.trim() ? { model: model.trim() } : {}),
        userId,
      };
      const [o, d, p, m] = await Promise.all([
        fetchGatewayAnalyticsOverview(token, base),
        fetchGatewayAnalyticsDaily(token, base),
        fetchGatewayAnalyticsDimension(token, { ...base, dimension: "provider", limit: 10 }),
        fetchGatewayAnalyticsDimension(token, { ...base, dimension: "model", limit: 10 }),
      ]);
      setOverview(o);
      setDaily(d);
      setByProvider(p);
      setByModel(m);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [endDate, groupId, model, providerId, startDate, token, userId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const comboData = useMemo(
    () => daily.map((d) => ({ date: d.date, count: d.count, tokens: d.total, cost: d.cost })),
    [daily]
  );

  return (
    <Stack spacing={2}>
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
        <UserFilterControl isAdmin={isAdmin} members={members} value={filterUserId} onChange={setFilterUserId} t={t} />
        <TextField size="small" type="date" sx={{ width: 160 }} label="start" value={startDate} onChange={(e) => setStartDate(e.target.value)} InputLabelProps={{ shrink: true }} />
        <TextField size="small" type="date" sx={{ width: 160 }} label="end" value={endDate} onChange={(e) => setEndDate(e.target.value)} InputLabelProps={{ shrink: true }} />
        <Button size="small" onClick={() => applyShortcut(1)}>today</Button>
        <Button size="small" onClick={() => applyShortcut(7)}>7d</Button>
        <Button size="small" onClick={() => applyShortcut(30)}>30d</Button>
        <TextField size="small" sx={{ width: 140 }} label={t("settings.gateway.filters.provider")} value={providerId} onChange={(e) => setProviderId(e.target.value)} />
        <TextField size="small" sx={{ width: 120 }} label={t("settings.gateway.filters.group")} value={groupId} onChange={(e) => setGroupId(e.target.value)} />
        <TextField size="small" sx={{ width: 160 }} label={t("settings.gateway.filters.model")} value={model} onChange={(e) => setModel(e.target.value)} />
        <Button size="small" startIcon={<RefreshIcon />} onClick={() => void reload()}>{t("settings.gateway.refresh")}</Button>
      </Stack>
      {error ? <Alert severity="error">{error}</Alert> : null}
      {loading && !overview ? (
        <Stack direction="row" spacing={1} alignItems="center"><CircularProgress size={20} /><Typography>{t("settings.gateway.loading")}</Typography></Stack>
      ) : null}
      <Grid container spacing={1.5}>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle2" color="text.secondary">tokens</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>{formatCount(overview?.total ?? 0)}</Typography>
            <Typography variant="caption" color="text.secondary" sx={{ mt: 1, display: "block" }}>
              in {formatCount(overview?.input ?? 0)} · out {formatCount(overview?.output ?? 0)} · hit {overview?.cacheHitRate ?? 0}%
            </Typography>
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle2" color="text.secondary">requests</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>{formatCount(overview?.count ?? 0)}</Typography>
            <Typography variant="caption" color="text.secondary" sx={{ mt: 1, display: "block" }}>
              uncached-in {formatCount(overview?.uncachedInput ?? 0)} · reasoning {formatCount(overview?.reasoning ?? 0)}
            </Typography>
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle2" color="text.secondary">cost</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>{formatMoney(overview?.cost ?? 0)}</Typography>
            <Typography variant="caption" color="text.secondary" sx={{ mt: 1, display: "block" }}>
              cache-w {formatCount(overview?.cacheWrite ?? 0)} · cached-r {formatCount(overview?.cachedRead ?? 0)}
            </Typography>
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, sm: 6, md: 3 }}>
          <Paper sx={{ p: 2, height: "100%" }}>
            <Typography variant="subtitle2" color="text.secondary">avg/req</Typography>
            <Typography variant="h4" sx={{ fontWeight: 900, fontFamily: "monospace", mt: 1 }}>
              {(overview?.count ?? 0) > 0 ? formatCount(Math.round((overview?.total ?? 0) / (overview?.count ?? 1))) : "—"}
            </Typography>
            <Typography variant="caption" color="text.secondary" sx={{ mt: 1, display: "block" }}>
              tokens per request
            </Typography>
          </Paper>
        </Grid>
      </Grid>
      <Paper sx={{ p: 2 }}>
        <Typography variant="subtitle1" sx={{ fontWeight: 800, mb: 1 }}>daily trend</Typography>
        <DailyComboChart data={comboData} />
      </Paper>
      <Grid container spacing={1.5}>
        <Grid size={{ xs: 12, md: 6 }}>
          <Paper sx={{ p: 2 }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 800, mb: 1 }}>by provider</Typography>
            <ReqCostBars rows={byProvider.map((r) => ({ name: r.name, count: r.count, cost: r.cost }))} />
            <TokenGroupedBars rows={byProvider.map((r) => ({ name: r.name, input: r.input, output: r.output, cached: r.cached }))} />
            <RankLegend rows={byProvider.map((r) => ({ name: r.name, total: r.total }))} totalKey="total" />
          </Paper>
        </Grid>
        <Grid size={{ xs: 12, md: 6 }}>
          <Paper sx={{ p: 2 }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 800, mb: 1 }}>by model</Typography>
            <ReqCostBars rows={byModel.map((r) => ({ name: r.name, count: r.count, cost: r.cost }))} />
            <TokenGroupedBars rows={byModel.map((r) => ({ name: r.name, input: r.input, output: r.output, cached: r.cached }))} />
            <RankLegend rows={byModel.map((r) => ({ name: r.name, total: r.total }))} totalKey="total" />
          </Paper>
        </Grid>
      </Grid>
    </Stack>
  );
}

function formatTs(ms: number): string {
  if (!ms) return "—";
  try {
    return new Date(ms).toLocaleString();
  } catch {
    return String(ms);
  }
}

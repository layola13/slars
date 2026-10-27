import { Box, Tooltip } from "@mui/material";
import { cliPlugin, cliPluginId } from "../app/cli/cliPlugins";
import { normalizeThreadCliBackend } from "../app/cli/cliBackendKind";
import type { CliBackend } from "@codex-ui/shared";

type Props = {
  cliBackend?: string | null;
  /** Optional tooltip describing which CLI the conversation uses. */
  label?: string;
  size?: number;
};

/**
 * Renders the CLI logo from the shared plugin registry so the top tab strip,
 * picker, and switcher stay in sync. An unregistered backend renders its
 * raw id as a monogram — never another backend's icon.
 */
export function CliBackendIcon({ cliBackend, label, size = 16 }: Props) {
  const normalized = normalizeThreadCliBackend(cliBackend);
  const pluginId = cliPluginId(normalized as CliBackend);
  const plugin = cliPlugin(pluginId);
  if (!plugin.icon) {
    const monogram = (
      <Box
        component="span"
        aria-hidden={label ? undefined : true}
        sx={{ width: size, height: size, flex: "0 0 auto", display: "inline-flex", alignItems: "center", justifyContent: "center", fontSize: Math.max(8, size * 0.55), fontWeight: 700, lineHeight: 1 }}
      >
        {plugin.label.slice(0, 1).toUpperCase()}
      </Box>
    );
    return label ? <Tooltip title={label}>{monogram}</Tooltip> : monogram;
  }
  const img = (
    <Box
      component="img"
      src={plugin.icon}
      alt={`${plugin.label} CLI`}
      aria-hidden={label ? undefined : true}
      sx={{ width: size, height: size, flex: "0 0 auto", objectFit: "contain", display: "block" }}
    />
  );
  return label ? <Tooltip title={label}>{img}</Tooltip> : img;
}

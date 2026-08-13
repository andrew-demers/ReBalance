<?php
/**
 * ReBalance — AJAX status / control endpoint
 * Accessible at: /plugins/rebalance/scripts/status.php
 */

// Capture any stray output (warnings, BOM, whitespace) so it never corrupts JSON
ob_start();

// Suppress PHP warnings/notices
ini_set('display_errors', 0);
error_reporting(0);

header('Content-Type: application/json');
header('Cache-Control: no-store, no-cache');

define('STATUS_FILE', '/tmp/rebalance_status.json');
define('LOCK_FILE',   '/tmp/rebalance.lock');
define('SCRIPT',      '/usr/local/emhttp/plugins/rebalance/scripts/rebalance.sh');

// ── Helper: check if a PID is alive without requiring posix extension ─────────
function pid_alive(int $pid): bool {
    if ($pid <= 0) return false;
    if (function_exists('posix_kill')) return posix_kill($pid, 0);
    return file_exists("/proc/$pid");
}

// ── Helper: is the background script currently running? ──────────────────────
function is_running(): bool {
    if (!file_exists(LOCK_FILE)) return false;
    $pid = (int) file_get_contents(LOCK_FILE);
    return pid_alive($pid);
}

// ── Helper: detect Unraid cache pool mount points from disks.ini ─────────────
function detect_cache_pools(): array {
    $pools = [];
    $ini = @parse_ini_file('/var/local/emhttp/disks.ini', true);
    if ($ini) {
        foreach ($ini as $section => $disk) {
            if (strtolower($disk['type'] ?? '') === 'cache') {
                $name = trim($disk['name'] ?? $section);
                $path = '/mnt/' . $name;
                $total = @disk_total_space($path);
                $free  = @disk_free_space($path);
                if ($total > 0) {
                    $pools[] = [
                        'name'    => $name,
                        'path'    => $path,
                        'size_kb' => (int)($total / 1024),
                        'free_kb' => (int)($free  / 1024),
                    ];
                }
            }
        }
    }
    // Fallback to /mnt/cache if nothing found via disks.ini
    if (empty($pools)) {
        $total = @disk_total_space('/mnt/cache');
        $free  = @disk_free_space('/mnt/cache');
        if ($total > 0) {
            $pools[] = [
                'name'    => 'cache',
                'path'    => '/mnt/cache',
                'size_kb' => (int)($total / 1024),
                'free_kb' => (int)($free  / 1024),
            ];
        }
    }
    return $pools;
}

// ── Helper: read live disk stats directly from the OS ───────────────────────
function live_disk_stats(int $tolerance): array {
    $mounts = glob('/mnt/disk[0-9]*') ?: [];
    natsort($mounts);

    $total_size = 0;
    $total_used = 0;
    $raw = [];

    foreach ($mounts as $mount) {
        if (!is_dir($mount)) continue;
        $total  = @disk_total_space($mount);
        $free   = @disk_free_space($mount);
        if ($total === false || $total == 0) continue;

        $used        = $total - $free;
        $total_size += $total;
        $total_used += $used;

        $raw[] = [
            'name'    => basename($mount),
            'mount'   => $mount,
            'size_kb' => (int)($total / 1024),
            'used_kb' => (int)($used  / 1024),
            'free_kb' => (int)($free  / 1024),
            'pct'     => ($total > 0) ? (int)round($used * 100 / $total) : 0,
            'role'    => 'balanced',
        ];
    }

    $target_pct = ($total_size > 0) ? (int)round($total_used * 100 / $total_size) : 0;

    foreach ($raw as &$d) {
        if      ($d['pct'] > $target_pct + $tolerance) $d['role'] = 'source';
        elseif  ($d['pct'] < $target_pct - $tolerance) $d['role'] = 'destination';
    }
    unset($d);

    return ['disks' => array_values($raw), 'target_pct' => $target_pct];
}

// ── Helper: build idle status payload ───────────────────────────────────────
function idle_payload(int $tolerance, ?array $existing = null): array {
    $stats = live_disk_stats($tolerance);

    $base = [
        'state'        => 'idle',
        'dry_run'      => false,
        'tolerance'    => $tolerance,
        'target_pct'   => $stats['target_pct'],
        'elapsed_sec'  => 0,
        'current_file' => '',
        'stats' => [
            'files_total'    => 0,
            'files_done'     => 0,
            'files_skipped'  => 0,
            'bytes_total_kb' => 0,
            'bytes_done_kb'  => 0,
            'pct_done'       => 0,
            'rate_kbs'       => 0,
            'eta_sec'        => 0,
        ],
        'plan_count' => 0,
        'disks'      => $stats['disks'],
        'plan'       => [],
        'log'        => [],
    ];

    // Overlay a completed/stopped/planned run's plan + log if present
    if ($existing && in_array($existing['state'] ?? '', ['completed', 'stopped', 'planned', 'error'])) {
        $base['state']       = $existing['state'];
        $base['stats']       = $existing['stats']       ?? $base['stats'];
        $base['plan_count']  = $existing['plan_count']  ?? 0;
        $base['plan']        = $existing['plan']        ?? [];
        $base['log']         = $existing['log']         ?? [];
        $base['dry_run']     = $existing['dry_run']     ?? false;
        $base['tolerance']   = $existing['tolerance']   ?? $tolerance;
    }

    return $base;
}

// ── Helper: launch background script ────────────────────────────────────────
// Close stdin (</dev/null) so the child is fully detached from the PHP-FPM
// worker. exec() with & returns immediately; proc_open+proc_close blocks
// until the child exits, so we avoid proc_open here.
function launch_script(string $cmd): bool {
    $shell_cmd = 'nohup ' . $cmd . ' </dev/null >/dev/null 2>&1 &';
    if (function_exists('exec')) {
        exec($shell_cmd);
        return true;
    }
    if (function_exists('shell_exec')) {
        shell_exec($shell_cmd);
        return true;
    }
    return false;
}

// ── Helper: discard buffered stray output, then emit JSON ───────────────────
function json_out($data): void {
    ob_clean();
    echo json_encode($data);
}

// ════════════════════════════════════════════════════════════════════════════
// Main handler — wrapped so any unexpected error still returns JSON
// ════════════════════════════════════════════════════════════════════════════
try {

// ── POST — control actions ───────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action        = $_POST['action']         ?? '';
    $tolerance     = max(1, min(20, (int)($_POST['tolerance']      ?? 2)));
    $dry_run       = !empty($_POST['dry_run']);
    $use_cache     = !empty($_POST['use_cache']);
    $cache_buffer  = max(10485760, min(2097152000, (int)($_POST['cache_buffer_kb'] ?? 104857600)));
    $stage_dir     = trim($_POST['stage_dir']    ?? '');
    $min_file_kb   = max(0, (int)($_POST['min_file_kb'] ?? 0));

    if ($action === 'start') {
        if (is_running()) {
            json_out(['success' => false, 'msg' => 'Already running']);
            exit;
        }

        if (!file_exists(SCRIPT)) {
            json_out(['success' => false, 'msg' => 'Script not found: ' . SCRIPT]);
            exit;
        }

        // Resolve staging directory: use user-supplied value, or auto-detect
        if ($stage_dir === '') {
            $pools = detect_cache_pools();
            $stage_dir = !empty($pools) ? $pools[0]['path'] . '/.rebalance_stage' : '/mnt/cache/.rebalance_stage';
        }

        $args  = '--tolerance ' . escapeshellarg((string)$tolerance);
        if ($dry_run)   $args .= ' --dry-run';
        if ($use_cache) $args .= ' --use-cache --cache-buffer ' . escapeshellarg((string)$cache_buffer)
                               . ' --stage-dir ' . escapeshellarg($stage_dir);
        if ($min_file_kb > 0) $args .= ' --min-file-kb ' . escapeshellarg((string)$min_file_kb);
        $cmd   = escapeshellarg(SCRIPT) . ' ' . $args;

        $ok = launch_script($cmd);
        if (!$ok) {
            json_out(['success' => false, 'msg' => 'Unable to launch script (proc_open/exec/shell_exec all unavailable)']);
            exit;
        }

        // Brief pause so the script can write its initial status
        usleep(400000);
        json_out(['success' => true]);
        exit;
    }

    if ($action === 'stop') {
        $stop_cmd = escapeshellarg(SCRIPT) . ' --stop';
        $out = [];
        if (function_exists('exec')) {
            exec($stop_cmd, $out);
        } else {
            $out[] = shell_exec($stop_cmd) ?: 'stop sent';
        }
        json_out(['success' => true, 'msg' => implode(' ', $out)]);
        exit;
    }

    if ($action === 'clear') {
        @unlink(STATUS_FILE);
        json_out(idle_payload($tolerance));
        exit;
    }

    json_out(['success' => false, 'msg' => 'Unknown action: ' . $action]);
    exit;
}

// ── GET — return current status ──────────────────────────────────────────────
$tolerance = max(1, min(20, (int)($_GET['tolerance'] ?? 2)));

if (is_running()) {
    if (file_exists(STATUS_FILE)) {
        // Script is running and has already written its status file
        ob_clean();
        echo file_get_contents(STATUS_FILE);
    } else {
        // Script just started — lock file exists but status not written yet.
        // Return a synthetic 'starting' payload so the poller keeps going.
        $live = live_disk_stats($tolerance);
        json_out([
            'state'          => 'starting',
            'dry_run'        => false,
            'use_cache'      => false,
            'cache_buffer_kb'=> 0,
            'cache_staged_kb'=> 0,
            'tolerance'      => $tolerance,
            'target_pct'     => $live['target_pct'],
            'elapsed_sec'    => 0,
            'current_file'   => '',
            'stats' => [
                'files_total'   => 0, 'files_done'     => 0,
                'files_skipped' => 0, 'bytes_total_kb' => 0,
                'bytes_done_kb' => 0, 'pct_done'       => 0,
                'rate_kbs'      => 0, 'eta_sec'        => 0,
            ],
            'plan_count' => 0,
            'plan'       => [],
            'log'        => [],
            'disks'      => $live['disks'],
        ]);
    }
    exit;
}

$existing = null;
if (file_exists(STATUS_FILE)) {
    $existing = json_decode(file_get_contents(STATUS_FILE), true);
}

$payload = idle_payload($tolerance, $existing);
$payload['cache_pools'] = detect_cache_pools();
json_out($payload);

} catch (Throwable $e) {
    json_out(['success' => false, 'msg' => 'PHP error: ' . $e->getMessage()]);
}

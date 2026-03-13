#!/usr/bin/env php
<?php

declare(strict_types=1);

// path: /root/scripts/backup-all.php
// Parallel backup script using pcntl_fork().
// Replaces the sequential backup-all.sh with concurrent execution.
//
// Usage:
//   php /root/scripts/backup-all.php            # normal run
//   php /root/scripts/backup-all.php --dry-run   # show what would be executed

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "This script must be run from the CLI.\n");
    exit(1);
}

if (!function_exists('pcntl_fork')) {
    fwrite(STDERR, "pcntl extension is required. Check: php -m | grep pcntl\n");
    exit(1);
}

require_once __DIR__ . '/dmarc/vendor/autoload.php';

use Monolog\Logger;
use Monolog\Handler\StreamHandler;
use Monolog\Handler\FingersCrossedHandler;
use Monolog\Formatter\LineFormatter;

umask(0077);

// ---------------------------------------------------------------------------

/**
 * Orchestrates parallel server backups via pcntl_fork() and syncs
 * the result to a Hetzner Storage Box. Individual backup tasks
 * (home, nginx, repo, forgejo, php8, mailcow, mysql, nextcloud) run concurrently;
 * rsync to offsite storage runs only when all tasks succeed.
 */
class BackupRunner
{
    private const BACKUP_DIR            = '/root/backup';
    private const MAILCOW_BACKUP_DIR    = '/root/backup/mailcow';
    private const MAILCOW_BACKUP_SCRIPT = '/root/scripts/mailcow-backup.sh';
    private const OCC_CMD               = '/usr/bin/php /srv/www/vhosts/example.com/sync.example.com/occ';
    private const NC_DB_NAME            = 'myapp_db';
    private const LOCK_FILE             = '/var/lock/backup-all.lock';

    private const STORAGEBOX_USER = 'uXXXXXX';
    private const STORAGEBOX_HOST = 'uXXXXXX.your-storagebox.de';
    private const STORAGEBOX_PORT = 23;
    private const STORAGEBOX_DIR  = '/home/backup';

    private const COMPRESS_PROGRAM = 'pigz -1';

    /** @var Logger */
    private Logger $log;

    /** @var bool */
    private bool $dryRun;

    /** @var bool Whether stdout is a terminal (controls ANSI color output). */
    private bool $useColors;

    /** @var resource|null */
    private $lockFp = null;

    /** @var int PID of the process that created this instance (fork safety). */
    private int $parentPid;

    /** @var string Today's date (Y-m-d), set in run(). */
    private string $date = '';

    /**
     * @param Logger $log    Monolog logger instance (writes to stdout).
     * @param bool   $dryRun If true, commands are logged but not executed.
     */
    public function __construct(Logger $log, bool $dryRun)
    {
        $this->log = $log;
        $this->dryRun = $dryRun;
        $this->useColors = stream_isatty(STDOUT);
        $this->parentPid = getmypid();
    }

    /**
     * Releases the file lock on destruction — but only in the parent process.
     * Forked children inherit the object; without this guard they would
     * release the parent's flock when they exit.
     */
    public function __destruct()
    {
        if (getmypid() === $this->parentPid) {
            $this->releaseLock();
        }
    }

    // -----------------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------------

    /**
     * Main entry point. Acquires lock, cleans old backups, forks parallel
     * tasks, waits for completion, rsyncs to offsite storage and prints
     * a summary table.
     *
     * @return int Exit code (0 = success, 1 = error).
     */
    public function run(): int
    {
        $this->acquireLock();

        $startTotal = microtime(true);
        $this->date = (new \DateTimeImmutable())->format('Y-m-d');

        $this->log->info('Backup started', ['dry_run' => $this->dryRun]);

        if (!is_dir(self::BACKUP_DIR)) {
            mkdir(self::BACKUP_DIR, 0700, true);
        }

        // Step 1: Delete old static backups
        $this->log->info('Deleting old static backups');
        $this->exec('cleanup', 'find /root/backup -maxdepth 1 -type f -name "*-backup_*.tar.gz" -delete');
        $this->exec('cleanup', 'find /root/backup -maxdepth 1 -type f -name "nc-db-backup_*.sql.gz" -delete');

        // Step 2: Fork parallel tasks
        $tasks = $this->getTaskDefinitions();
        $results = $this->forkAndWait($tasks);

        $allOk = true;
        foreach ($results as $info) {
            if ($info['exit'] !== 0) {
                $allOk = false;
                break;
            }
        }

        // Step 3: Verify archives in parallel
        $archivePaths = $this->getArchivePaths();
        $verifyTasks = [];
        foreach ($results as $label => $info) {
            if ($info['exit'] !== 0 || !isset($archivePaths[$label])) {
                continue;
            }
            $archives = $archivePaths[$label];
            $verifyTasks[$label] = function () use ($label, $archives): int {
                foreach ($archives as $archive) {
                    $rc = $this->verifyArchive($label, $archive);
                    if ($rc !== 0) {
                        return $rc;
                    }
                }
                return 0;
            };
        }

        $this->log->info('verify archive');
        $verifyResults = $this->forkAndWait($verifyTasks);

        foreach ($verifyResults as $label => $info) {
            $results[$label]['verify'] = $info['exit'] === 0 ? 'OK' : 'ERROR';
            if ($info['exit'] !== 0) {
                $allOk = false;
            }
        }
        foreach ($results as $label => $info) {
            if (!isset($info['verify'])) {
                $results[$label]['verify'] = $info['exit'] === 0 ? '-' : 'SKIP';
            }
        }

        // Step 4: Rsync to Storage Box (always — partial backups are better than none)
        if (!$allOk) {
            $this->log->warning('Not all tasks successful — execute sync anyway');
        }
        $rsyncResult = $this->syncToStorageBox();
        $results['rsync'] = $rsyncResult;
        if ($rsyncResult['exit'] !== 0) {
            $allOk = false;
        }

        // Summary
        $totalDuration = microtime(true) - $startTotal;
        $this->printSummary($results, $totalDuration);

        $context = [
            'duration' => $this->formatDuration($totalDuration),
            'size'     => $this->formatSize($this->getDirectorySize(self::BACKUP_DIR)),
        ];
        if ($allOk) {
            $this->log->info('Backup completed successfully', $context);
        } else {
            $this->log->error('Backup finished with errors', $context);
        }

        return $allOk ? 0 : 1;
    }

    // -----------------------------------------------------------------------
    // Lock
    // -----------------------------------------------------------------------

    /**
     * Acquires an exclusive, non-blocking file lock to prevent parallel runs.
     *
     * @throws \RuntimeException If another instance already holds the lock.
     */
    private function acquireLock(): void
    {
        $this->lockFp = fopen(self::LOCK_FILE, 'c');
        if ($this->lockFp === false || !flock($this->lockFp, LOCK_EX | LOCK_NB)) {
            throw new \RuntimeException('Backup already running — aborting.');
        }
    }

    /**
     * Releases the file lock and closes the lock file handle.
     */
    private function releaseLock(): void
    {
        if ($this->lockFp !== null) {
            flock($this->lockFp, LOCK_UN);
            fclose($this->lockFp);
            $this->lockFp = null;
        }
    }

    // -----------------------------------------------------------------------
    // Shell execution
    // -----------------------------------------------------------------------

    /**
     * Executes a shell command via exec(). Output is captured and only
     * logged on failure — nothing leaks to stdout. In dry-run mode the
     * command is logged but not executed.
     *
     * @param string $label   Human-readable task name for log messages.
     * @param string $command Shell command to execute.
     *
     * @return int Exit code (always 0 in dry-run mode).
     */
    private function exec(string $label, string $command): int
    {
        if ($this->dryRun) {
            $this->log->info('[DRY-RUN] Command skipped', ['task' => $label, 'command' => $command]);
            return 0;
        }

        $this->log->info('Executing command', ['task' => $label, 'command' => $command]);
        $output = [];
        $exitCode = 0;
        exec($command . ' 2>&1', $output, $exitCode);

        if ($exitCode !== 0 && $output !== []) {
            $this->log->error('Command output', ['task' => $label, 'output' => implode("\n", $output)]);
        }

        return $exitCode;
    }

    /**
     * Creates a tar.gz archive using -C for relative paths.
     *
     * @param string $label   Human-readable task name for log messages.
     * @param string $archive Absolute path of the output .tar.gz file.
     * @param string $srcDir  Base directory passed to tar -C.
     * @param string $path    Relative path within $srcDir to archive.
     *
     * @return int Exit code from tar.
     */
    private function tarc(string $label, string $archive, string $srcDir, string $path): int
    {
        $cmd = sprintf(
            'tar -C %s --use-compress-program=%s -cf %s %s',
            escapeshellarg($srcDir),
            escapeshellarg(self::COMPRESS_PROGRAM),
            escapeshellarg($archive),
            escapeshellarg($path)
        );
        return $this->exec($label, $cmd);
    }

    /**
     * Verifies a compressed archive by listing its contents (tar.gz)
     * or testing gzip integrity (.sql.gz). Returns 0 on success.
     *
     * @param string $label   Human-readable task name for log messages.
     * @param string $archive Absolute path of the archive to verify.
     *
     * @return int Exit code (0 = archive intact).
     */
    private function verifyArchive(string $label, string $archive): int
    {
        if (str_ends_with($archive, '.tar.gz')) {
            $cmd = sprintf(
                'tar --use-compress-program=pigz -tf %s > /dev/null',
                escapeshellarg($archive)
            );
        } else {
            $cmd = sprintf('pigz -t %s', escapeshellarg($archive));
        }

        return $this->exec($label, $cmd);
    }

    /**
     * Returns the expected archive paths for each backup task.
     * Used to verify archives after creation.
     *
     * @return array<string, list<string>> Task label => list of archive paths.
     */
    private function getArchivePaths(): array
    {
        return [
            'home'      => [self::BACKUP_DIR . "/home-backup_{$this->date}.tar.gz"],
            'nginx'     => [self::BACKUP_DIR . "/nginx-backup_{$this->date}.tar.gz"],
            'repo'      => [self::BACKUP_DIR . "/repo-backup_{$this->date}.tar.gz"],
            'forgejo'   => [self::BACKUP_DIR . "/forgejo-backup_{$this->date}.tar.gz"],
            'php8'      => [self::BACKUP_DIR . "/php8-backup_{$this->date}.tar.gz"],
            'mysql'     => [self::BACKUP_DIR . "/mysql-backup_{$this->date}.tar.gz"],
            'nextcloud' => [
                self::BACKUP_DIR . "/nc-db-backup_{$this->date}.sql.gz",
                self::BACKUP_DIR . "/vhosts-backup_{$this->date}.tar.gz",
            ],
        ];
    }

    // -----------------------------------------------------------------------
    // Task definitions
    // -----------------------------------------------------------------------

    /**
     * Returns an associative array of backup task callables keyed by label.
     * Each callable returns an int exit code when invoked.
     *
     * @return array<string, callable(): int> Label => callable returning exit code.
     */
    private function getTaskDefinitions(): array
    {
        return [
            'home'      => [$this, 'backupHome'],
            'nginx'     => [$this, 'backupNginx'],
            'repo'      => [$this, 'backupRepo'],
            'forgejo'   => [$this, 'backupForgejo'],
            'php8'      => [$this, 'backupPhp8'],
            'mailcow'   => [$this, 'backupMailcow'],
            'mysql'     => [$this, 'backupMysql'],
            'nextcloud' => [$this, 'backupNextcloud'],
        ];
    }

    private function backupHome(): int
    {
        return $this->tarc('home', self::BACKUP_DIR . "/home-backup_{$this->date}.tar.gz", '/', 'home');
    }

    private function backupNginx(): int
    {
        return $this->tarc('nginx', self::BACKUP_DIR . "/nginx-backup_{$this->date}.tar.gz", '/', 'etc/nginx');
    }

    private function backupRepo(): int
    {
        return $this->tarc('repo', self::BACKUP_DIR . "/repo-backup_{$this->date}.tar.gz", '/', 'srv/repo');
    }

    private function backupForgejo(): int
    {
        return $this->tarc('forgejo', self::BACKUP_DIR . "/forgejo-backup_{$this->date}.tar.gz", '/', 'var/lib/forgejo');
    }

    private function backupPhp8(): int
    {
        return $this->tarc('php8', self::BACKUP_DIR . "/php8-backup_{$this->date}.tar.gz", '/', 'etc/php8');
    }

    private function backupMailcow(): int
    {
        putenv('MAILCOW_BACKUP_LOCATION=' . self::MAILCOW_BACKUP_DIR);
        return $this->exec('mailcow', self::MAILCOW_BACKUP_SCRIPT);
    }

    /**
     * Dumps all MySQL databases and compresses the result.
     * Uses --single-transaction for a consistent snapshot without locks.
     *
     * @return int Exit code (0 = success).
     */
    private function backupMysql(): int
    {
        $sqlFile = self::BACKUP_DIR . "/mysql-backup_{$this->date}.sql";
        $tarFile = self::BACKUP_DIR . "/mysql-backup_{$this->date}.tar.gz";

        $rc = $this->exec(
            'mysql',
            'mysqldump --tz-utc --all-databases --single-transaction --routines --triggers --events --hex-blob'
                . ' -r ' . escapeshellarg($sqlFile)
        );
        if ($rc !== 0) {
            return $rc;
        }

        $rc = $this->exec('mysql', sprintf(
            'tar -C %s --use-compress-program=%s -cf %s %s',
            escapeshellarg(self::BACKUP_DIR),
            escapeshellarg(self::COMPRESS_PROGRAM),
            escapeshellarg($tarFile),
            escapeshellarg(basename($sqlFile))
        ));
        if ($rc !== 0) {
            return $rc;
        }

        if (!$this->dryRun) {
            unlink($sqlFile);
        }

        return 0;
    }

    /**
     * Backs up Nextcloud in two phases:
     *
     * Phase 1 – Consistent DB dump with minimal maintenance window:
     *   maintenance:mode --on  →  mysqldump --single-transaction  →  maintenance:mode --off
     *   This takes only seconds instead of the 30-60+ minutes that the previous
     *   full-vhosts tar required, preventing sync failures for connected clients.
     *
     * Phase 2 – Vhosts archive WITHOUT maintenance mode:
     *   Application files do not change at runtime, so no lock is needed.
     *   The data directory may receive writes, but InnoDB consistency is already
     *   guaranteed by the --single-transaction dump from phase 1.
     *
     * @return int Exit code (0 = success, 1 = any step failed).
     */
    private function backupNextcloud(): int
    {
        // -- Phase 1: Short maintenance window for NC database dump -----------

        $this->log->info('Enabling maintenance mode (DB dump)', ['task' => 'nextcloud']);
        $rc = $this->exec('nextcloud', 'sudo -u nginx ' . self::OCC_CMD . ' maintenance:mode --on');
        if ($rc !== 0) {
            $this->log->error('maintenance:mode --on failed', [
                'task'      => 'nextcloud',
                'exit_code' => $rc,
            ]);
            return $rc;
        }

        $sqlFile  = self::BACKUP_DIR . "/nc-db-backup_{$this->date}.sql";
        $dumpFile = $sqlFile . '.gz';
        $dbExitCode = 0;
        try {
            $dbExitCode = $this->exec(
                'nextcloud',
                'mysqldump --tz-utc --single-transaction --routines --triggers --hex-blob'
                    . ' -r ' . escapeshellarg($sqlFile)
                    . ' ' . escapeshellarg(self::NC_DB_NAME)
            );
            if ($dbExitCode === 0) {
                $dbExitCode = $this->exec('nextcloud', self::COMPRESS_PROGRAM . ' ' . escapeshellarg($sqlFile));
            }
        } finally {
            $this->log->info('Disabling maintenance mode', ['task' => 'nextcloud']);
            $rcOff = $this->exec('nextcloud', 'sudo -u nginx ' . self::OCC_CMD . ' maintenance:mode --off');
            if ($rcOff !== 0) {
                $this->log->error('maintenance:mode --off failed', [
                    'task'      => 'nextcloud',
                    'exit_code' => $rcOff,
                ]);
                $dbExitCode = 1;
            }
        }

        if ($dbExitCode !== 0) {
            return $dbExitCode;
        }

        // -- Phase 2: Vhosts archive without maintenance mode -----------------

        $this->log->info('Creating vhosts archive (without maintenance mode)', ['task' => 'nextcloud']);

        return $this->tarc(
            'vhosts',
            self::BACKUP_DIR . "/vhosts-backup_{$this->date}.tar.gz",
            '/',
            'srv/www/vhosts'
        );
    }

    // -----------------------------------------------------------------------
    // Process management
    // -----------------------------------------------------------------------

    /**
     * Forks one child process per task, executes all tasks in parallel
     * and waits for every child to finish.
     *
     * @param array<string, callable(): int> $tasks Label => callable returning exit code.
     *
     * @return array<string, array{exit: int, duration: float}> Results keyed by label.
     */
    private function forkAndWait(array $tasks): array
    {
        $children  = []; // label => pid
        $taskStart = []; // label => microtime

        foreach ($tasks as $label => $taskFn) {
            $pid = pcntl_fork();

            if ($pid === -1) {
                $this->log->error('Fork failed', ['task' => $label]);
                continue;
            }

            if ($pid === 0) {
                // Child process
                $rc = $taskFn();
                exit($rc);
            }

            // Parent
            $children[$label]  = $pid;
            $taskStart[$label] = microtime(true);
            $this->log->info('Task started', ['task' => $label, 'pid' => $pid]);
        }

        // Wait for all children
        $results = [];

        while (count($results) < count($children)) {
            $status = 0;
            $pid = pcntl_wait($status);

            if ($pid <= 0) {
                break;
            }

            $exitCode = pcntl_wifexited($status) ? pcntl_wexitstatus($status) : 1;
            $label = array_search($pid, $children, true);

            if ($label === false) {
                continue;
            }

            $duration = microtime(true) - $taskStart[$label];
            $results[$label] = ['exit' => $exitCode, 'duration' => $duration];

            if ($exitCode !== 0) {
                $this->log->error('Task failed', [
                    'task'      => $label,
                    'exit_code' => $exitCode,
                    'duration'  => $this->formatDuration($duration),
                ]);
            } else {
                $this->log->info('Task completed', [
                    'task'     => $label,
                    'duration' => $this->formatDuration($duration),
                ]);
            }
        }

        return $results;
    }

    // -----------------------------------------------------------------------
    // Rsync
    // -----------------------------------------------------------------------

    /**
     * Syncs the backup directory to the Hetzner Storage Box via rsync over SSH.
     *
     * @return array{exit: int, duration: float} Exit code and elapsed time.
     */
    private function syncToStorageBox(): array
    {
        $this->log->info('Syncing to Storage Box', ['host' => self::STORAGEBOX_HOST]);

        $rsyncCmd = sprintf(
            '/usr/bin/rsync -az --delete -e %s %s %s',
            escapeshellarg('ssh -p ' . self::STORAGEBOX_PORT),
            escapeshellarg(self::BACKUP_DIR . '/'),
            escapeshellarg(self::STORAGEBOX_USER . '@' . self::STORAGEBOX_HOST . ':' . self::STORAGEBOX_DIR . '/')
        );

        $start = microtime(true);
        $rc = $this->exec('rsync', $rsyncCmd);
        $duration = microtime(true) - $start;

        if ($rc !== 0) {
            $this->log->error('Rsync failed', [
                'exit_code' => $rc,
                'duration'  => $this->formatDuration($duration),
            ]);
        } else {
            $this->log->info('Rsync completed', [
                'duration' => $this->formatDuration($duration),
            ]);
        }

        return ['exit' => $rc, 'duration' => $duration];
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    /**
     * Prints an ANSI-colored summary table of all task results to stdout.
     *
     * @param array<string, array{exit: int, duration: float}> $results Task results.
     * @param float $totalDuration Wall-clock time for the entire backup run.
     */
    private function printSummary(array $results, float $totalDuration): void
    {
        $totalSize = $this->getDirectorySize(self::BACKUP_DIR);

        echo "\n";
        echo $this->colorize("=== Summary ===", "\033[1m") . "\n";
        printf("%-12s %-10s %-10s %s\n", 'Task', 'Status', 'Verify', 'Duration');
        printf("%-12s %-10s %-10s %s\n", str_repeat('-', 12), str_repeat('-', 10), str_repeat('-', 10), str_repeat('-', 10));

        foreach ($results as $label => $info) {
            if ($info['exit'] === 0) {
                $statusStr = $this->colorize('OK', "\033[32m");
            } else {
                $statusStr = $this->colorize('ERROR(' . $info['exit'] . ')', "\033[31m");
            }

            $verify = $info['verify'] ?? '-';
            if ($verify === 'OK') {
                $verifyStr = $this->colorize('OK', "\033[32m");
            } elseif ($verify === 'ERROR') {
                $verifyStr = $this->colorize('ERROR', "\033[31m");
            } else {
                $verifyStr = $verify;
            }

            // Colorized strings contain invisible ANSI bytes — use wider field to compensate alignment.
            $statusWidth = $this->useColors ? 20 : 10;
            $verifyWidth = $this->useColors && in_array($verify, ['OK', 'ERROR'], true) ? 20 : 10;
            printf("%-12s %-{$statusWidth}s %-{$verifyWidth}s %s\n", $label, $statusStr, $verifyStr, $this->formatDuration($info['duration']));
        }

        echo str_repeat('-', 52) . "\n";
        printf("Total:      %s\n", $this->formatDuration($totalDuration));
        printf("Size:       %s\n", $this->formatSize($totalSize));
    }

    // -----------------------------------------------------------------------
    // Formatting helpers
    // -----------------------------------------------------------------------

    /**
     * Wraps text in ANSI color codes when stdout is a terminal.
     *
     * @param string $text  Text to colorize.
     * @param string $color ANSI escape sequence (e.g. "\033[32m").
     *
     * @return string Colorized string or plain text.
     */
    private function colorize(string $text, string $color): string
    {
        return $this->useColors ? ($color . $text . "\033[0m") : $text;
    }

    /**
     * Formats seconds into a human-readable duration string.
     *
     * @param float $seconds Elapsed time in seconds.
     *
     * @return string Formatted duration (e.g. "45s" or "3m 12s").
     */
    private function formatDuration(float $seconds): string
    {
        $s = (int) round($seconds);
        if ($s < 60) {
            return "{$s}s";
        }
        $m = intdiv($s, 60);
        $r = $s % 60;
        return "{$m}m {$r}s";
    }

    /**
     * Formats a byte count into a human-readable size string.
     *
     * @param int $bytes Size in bytes.
     *
     * @return string Formatted size (e.g. "1.23 GB" or "456.7 MB").
     */
    private function formatSize(int $bytes): string
    {
        $gb = $bytes / (1024 * 1024 * 1024);
        if ($gb >= 1.0) {
            return sprintf('%.2f GB', $gb);
        }
        $mb = $bytes / (1024 * 1024);
        return sprintf('%.1f MB', $mb);
    }

    /**
     * Calculates the total size of a directory recursively.
     *
     * @param string $path Absolute directory path.
     *
     * @return int Total size in bytes (0 if the path is not a directory).
     */
    private function getDirectorySize(string $path): int
    {
        if (!is_dir($path)) {
            return 0;
        }
        $size = 0;
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($path, RecursiveDirectoryIterator::SKIP_DOTS)
        );
        foreach ($iterator as $file) {
            if ($file->isFile()) {
                $size += $file->getSize();
            }
        }
        return $size;
    }
}

// ===========================================================================
// Bootstrap
// ===========================================================================

$dryRun = in_array('--dry-run', $argv, true);

$formatter = new LineFormatter("[%datetime%] [%level_name%] %message% %context%\n", 'H:i:s', false, true);
$streamHandler = new StreamHandler('php://stdout', Logger::DEBUG);
$streamHandler->setFormatter($formatter);
// Dry-run: full output for interactive debugging.
// Normal:  FingersCrossedHandler buffers INFO, flushes only on WARNING+.
$handler = $dryRun
    ? $streamHandler
    : new FingersCrossedHandler($streamHandler, Logger::WARNING);
$log = new Logger('backup');
$log->pushHandler($handler);

$runner = new BackupRunner($log, $dryRun);

exit($runner->run());

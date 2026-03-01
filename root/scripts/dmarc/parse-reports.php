#!/usr/bin/env php
<?php

declare(strict_types=1);

// path: /root/scripts/dmarc/parse-reports.php
// Parse DMARC aggregate reports from IMAP and write structured JSONL
// for Grafana Cloud Loki (via Alloy file tail).
//
// Dependencies (pure PHP, no extensions required):
//   - webklex/php-imap (IMAP connection + MIME parsing)
//   - monolog/monolog  (structured logging)
//
// Usage:
//   php /root/scripts/dmarc/parse-reports.php            # normal run
//   php /root/scripts/dmarc/parse-reports.php --dry-run   # parse & display, write nothing

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "This script must be run from the CLI.\n");
    exit(1);
}

require_once __DIR__ . '/vendor/autoload.php';

use Monolog\Logger;
use Monolog\Handler\StreamHandler;
use Monolog\Handler\FingersCrossedHandler;
use Monolog\Formatter\LineFormatter;
use Webklex\PHPIMAP\ClientManager;
use Webklex\PHPIMAP\Client;
use Webklex\PHPIMAP\Message;
use Webklex\PHPIMAP\Support\MessageCollection;


// ---------------------------------------------------------------------------

/**
 * Parses DMARC aggregate reports from an IMAP mailbox and writes
 * structured JSON lines to a log file for ingestion by Grafana Alloy/Loki.
 *
 * Supports ZIP, GZIP and plain XML attachments with automatic encoding
 * detection and conversion to UTF-8. Handles namespaced DMARC 2.0 XML
 * (e.g. GMX) transparently.
 */
class DmarcReportParser
{
    private const IMAP_HOST    = 'mail.example.com';
    private const IMAP_PORT    = 993;
    private const IMAP_USER    = 'admin@example.com';
    private const IMAP_PASS    = 'changeme';
    private const IMAP_MAILBOX   = 'INBOX';
    private const IMAP_PAGE_SIZE = 50;

    private const OUTPUT_FILE  = '/var/log/dmarc/reports.jsonl';
    private const LOCK_FILE    = '/var/lock/dmarc-report-parser.lock';
    private const STATE_FILE   = '/var/log/dmarc/processed.list';

    /** @var string[] Encoding detection order — most common DMARC report encodings first. */
    private const ENCODING_DETECT_ORDER = [
        'UTF-8', 'ASCII', 'ISO-8859-1', 'ISO-8859-15', 'Windows-1252',
    ];

    /** @var Logger */
    private Logger $log;

    /** @var bool */
    private bool $dryRun;

    /** @var Client|null */
    private ?Client $imapClient = null;

    /** @var resource|null */
    private $lockFp = null;

    /** @var array<string, true> Set of already-processed Message-IDs. */
    private array $processedIds = [];

    /**
     * @param Logger $log    Monolog logger instance (writes to STDERR).
     * @param bool   $dryRun If true, parses and prints but writes nothing.
     */
    public function __construct(Logger $log, bool $dryRun)
    {
        $this->log = $log;
        $this->dryRun = $dryRun;
    }

    /**
     * Ensures IMAP connection and file lock are released on object destruction,
     * even if the script terminates unexpectedly.
     */
    public function __destruct()
    {
        $this->disconnectImap();
        $this->releaseLock();
    }

    // -----------------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------------

    /**
     * Main entry point. Acquires lock, loads state, connects to IMAP,
     * fetches unprocessed DMARC reports, parses them and writes JSONL output.
     *
     * @return int Exit code (0 = success, 1 = error).
     */
    public function run(): int
    {
        $this->acquireLock();
        $this->processedIds = $this->loadProcessedIds();

        $this->log->info('DMARC report parser started', [
            'dry_run'        => $this->dryRun,
            'already_known'  => count($this->processedIds),
        ]);

        try {
            $this->connectImap();
            $jsonLines = $this->fetchAndParse();
        } catch (\Throwable $e) {
            $this->log->error('Fatal error', ['error' => $e->getMessage()]);
            return 1;
        }

        $totalRecords = count($jsonLines);

        if ($this->dryRun) {
            $this->log->info('DRY-RUN complete', [
                'records' => $totalRecords,
                'file'    => self::OUTPUT_FILE,
            ]);
            foreach ($jsonLines as $line) {
                fwrite(STDOUT, $line . "\n");
            }
        } elseif ($totalRecords > 0) {
            $this->writeJsonLines($jsonLines);
        } else {
            $this->log->info('No DMARC records found in any message.');
        }

        $this->saveProcessedIds();

        $this->log->info('Done', ['records' => $totalRecords]);
        return 0;
    }

    // -----------------------------------------------------------------------
    // IMAP
    // -----------------------------------------------------------------------

    /**
     * Establishes an SSL-encrypted IMAP connection to the configured mailbox.
     *
     * @throws \RuntimeException If the connection or authentication fails.
     */
    private function connectImap(): void
    {
        $cm = new ClientManager();
        $this->imapClient = $cm->make([
            'host'       => self::IMAP_HOST,
            'port'       => self::IMAP_PORT,
            'encryption' => 'ssl',
            'username'   => self::IMAP_USER,
            'password'   => self::IMAP_PASS,
            'protocol'   => 'imap',
        ]);

        try {
            $this->imapClient->connect();
        } catch (\Throwable $e) {
            $this->imapClient = null;
            throw new \RuntimeException('IMAP connection failed: ' . $e->getMessage(), 0, $e);
        }

        $this->log->info('Connected to IMAP', [
            'host' => self::IMAP_HOST,
            'port' => self::IMAP_PORT,
        ]);
    }

    /**
     * Closes the IMAP connection if one is open. Errors during
     * disconnect are silently ignored (best-effort cleanup).
     */
    private function disconnectImap(): void
    {
        if ($this->imapClient !== null) {
            try {
                $this->imapClient->disconnect();
            } catch (\Throwable) {
                // ignore — best effort cleanup
            }
            $this->imapClient = null;
        }
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
            throw new \RuntimeException('Another instance is already running — aborting.');
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
    // State (processed Message-IDs)
    // -----------------------------------------------------------------------

    /**
     * Loads the set of already-processed Message-IDs from the state file.
     * Returns an empty array if the file does not exist yet.
     *
     * @return array<string, true> Message-IDs as keys for O(1) lookup.
     */
    private function loadProcessedIds(): array
    {
        if (!is_file(self::STATE_FILE)) {
            return [];
        }
        $lines = file(self::STATE_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if ($lines === false) {
            return [];
        }
        return array_fill_keys($lines, true);
    }

    /**
     * Persists the current set of processed Message-IDs to the state file.
     * Skipped in dry-run mode to avoid side effects.
     */
    private function saveProcessedIds(): void
    {
        if ($this->dryRun) {
            return;
        }

        $dir = dirname(self::STATE_FILE);
        if (!is_dir($dir)) {
            mkdir($dir, 0750, true);
        }

        file_put_contents(self::STATE_FILE, implode("\n", array_keys($this->processedIds)) . "\n");
    }

    /**
     * Extracts a unique identifier from an IMAP message.
     * Prefers the standard Message-ID header; falls back to a combination
     * of UID and date if the header is missing.
     *
     * @param Message $message Webklex IMAP message object.
     *
     * @return string Unique message identifier.
     */
    private function getMessageId(Message $message): string
    {
        $messageId = $message->getMessageId();
        if ($messageId !== null) {
            $id = (string) $messageId;
            if ($id !== '') {
                return $id;
            }
        }
        // Fallback: UID + date (stable within the same mailbox)
        $date = $message->getDate();
        $dateStr = ($date !== null) ? (string) $date : '0';
        return 'uid-' . $message->getUid() . '-' . $dateStr;
    }

    // -----------------------------------------------------------------------
    // Fetch & parse
    // -----------------------------------------------------------------------

    /**
     * Queries the IMAP folder page by page ({@see IMAP_PAGE_SIZE}),
     * skips messages already recorded in the state file and processes the rest.
     * Individual message failures are logged but do not abort the run.
     *
     * @return string[] JSON-encoded lines from all newly processed messages.
     */
    private function fetchAndParse(): array
    {
        $folder = $this->imapClient->getFolder(self::IMAP_MAILBOX);

        $allJsonLines = [];
        $skipped  = 0;
        $page     = 1;

        do {
            /** @var MessageCollection $messages */
            $messages = $folder->query()->all()
                ->limit(self::IMAP_PAGE_SIZE, $page)
                ->get();

            $this->log->info('Fetching messages', [
                'page'  => $page,
                'count' => $messages->count(),
            ]);

            foreach ($messages as $message) {
                $messageId = $this->getMessageId($message);

                if (isset($this->processedIds[$messageId])) {
                    $skipped++;
                    continue;
                }

                try {
                    $lines = $this->processMessage($message);
                    $allJsonLines = array_merge($allJsonLines, $lines);
                    if (!$this->dryRun) {
                        $this->processedIds[$messageId] = true;
                    }
                } catch (\Throwable $e) {
                    $subject = (string) ($message->getSubject() ?? '(no subject)');
                    $this->log->error('Failed to process message', [
                        'subject'    => $subject,
                        'message_id' => $messageId,
                        'error'      => $e->getMessage(),
                    ]);
                }
            }

            $page++;
        } while ($messages->count() >= self::IMAP_PAGE_SIZE);

        if ($skipped > 0) {
            $this->log->info('Already processed — skipped', ['count' => $skipped]);
        }

        return $allJsonLines;
    }

    /**
     * Processes a single IMAP message: extracts DMARC XML from attachments
     * and parses each report into JSON lines.
     *
     * @param Message $message Webklex IMAP message object.
     *
     * @return string[] JSON-encoded lines extracted from this message.
     */
    private function processMessage(Message $message): array
    {
        $subject = (string) ($message->getSubject() ?? '(no subject)');
        $this->log->info('Processing message', ['subject' => $subject]);

        $attachments = $message->getAttachments();

        if ($attachments->count() === 0) {
            $this->log->info('No attachments in message — skipping', [
                'subject' => $subject,
                'message_id' => $this->getMessageId($message),
            ]);
            return [];
        }

        $jsonLines = [];

        foreach ($attachments as $attachment) {
            $filename = $attachment->getName() ?: 'unknown';
            $content  = $attachment->getContent();

            $xmlStrings = $this->extractXml($content, $filename);

            foreach ($xmlStrings as $xmlString) {
                try {
                    $lines = $this->parseDmarcXml($xmlString);
                    $jsonLines = array_merge($jsonLines, $lines);
                } catch (\Throwable $e) {
                    $this->log->warning('XML parse error', [
                        'filename' => $filename,
                        'error'    => $e->getMessage(),
                    ]);
                }
            }
        }

        $this->log->info('Records extracted', [
            'count'   => count($jsonLines),
            'subject' => $subject,
        ]);

        return $jsonLines;
    }

    // -----------------------------------------------------------------------
    // Attachment extraction
    // -----------------------------------------------------------------------

    /**
     * Extracts XML content from a mail attachment based on its file extension.
     * Supports .zip, .xml.gz, .gz and .xml. All returned strings are UTF-8.
     *
     * @param string $content  Raw binary attachment content.
     * @param string $filename Attachment filename (used for type detection).
     *
     * @return string[] Array of UTF-8 normalized XML strings.
     */
    private function extractXml(string $content, string $filename): array
    {
        $lower = mb_strtolower($filename, 'UTF-8');

        if ($this->mbEndsWith($lower, '.zip')) {
            return $this->extractFromZip($content, $filename);
        }

        if ($this->mbEndsWith($lower, '.xml.gz') || $this->mbEndsWith($lower, '.gz')) {
            $decoded = @gzdecode($content);
            if ($decoded === false) {
                $this->log->warning('gzdecode failed', ['filename' => $filename]);
                return [];
            }
            return [$this->normalizeToUtf8($decoded)];
        }

        if ($this->mbEndsWith($lower, '.xml')) {
            return [$this->normalizeToUtf8($content)];
        }

        $this->log->info('Skipping non-XML attachment', ['filename' => $filename]);
        return [];
    }

    /**
     * Extracts all .xml entries from a ZIP archive.
     * Writes the archive to a temporary file, extracts matching entries,
     * normalizes their encoding to UTF-8 and cleans up the temp file.
     *
     * @param string $content  Raw ZIP binary content.
     * @param string $filename Original attachment filename (for log messages).
     *
     * @return string[] Array of UTF-8 normalized XML strings from ZIP entries.
     */
    private function extractFromZip(string $content, string $filename): array
    {
        $tmpFile = tempnam(sys_get_temp_dir(), 'dmarc_');
        file_put_contents($tmpFile, $content);

        $xmlStrings = [];

        try {
            $zip = new \ZipArchive();
            if ($zip->open($tmpFile) !== true) {
                $this->log->warning('Failed to open ZIP', ['filename' => $filename]);
                return [];
            }

            for ($i = 0; $i < $zip->numFiles; $i++) {
                $name = $zip->getNameIndex($i);
                if ($this->mbEndsWith(mb_strtolower($name, 'UTF-8'), '.xml')) {
                    $xmlStrings[] = $this->normalizeToUtf8($zip->getFromIndex($i));
                }
            }
            $zip->close();
        } finally {
            @unlink($tmpFile);
        }

        return $xmlStrings;
    }

    // -----------------------------------------------------------------------
    // Encoding detection & normalization
    // -----------------------------------------------------------------------

    /**
     * Detects the encoding of raw XML content and converts it to UTF-8
     * if necessary. Also rewrites the encoding attribute in the XML
     * declaration to reflect the actual (converted) encoding.
     *
     * @param string $content Raw XML content in unknown encoding.
     *
     * @return string UTF-8 encoded XML content.
     */
    private function normalizeToUtf8(string $content): string
    {
        $sourceEncoding = $this->detectXmlEncoding($content);

        if ($sourceEncoding === 'UTF-8' || $sourceEncoding === 'ASCII') {
            return $content;
        }

        $this->log->info('Converting XML encoding', [
            'from' => $sourceEncoding,
            'to'   => 'UTF-8',
        ]);

        $converted = mb_convert_encoding($content, 'UTF-8', $sourceEncoding);

        // Rewrite encoding attribute in the XML declaration to match actual encoding
        $converted = preg_replace(
            '/(<\?xml[^>]+encoding=["\'])[^"\']+(["\'])/iu',
            '${1}UTF-8${2}',
            $converted
        );

        return $converted;
    }

    /**
     * Determines the character encoding of an XML string.
     * First checks the encoding attribute in the XML declaration
     * ({@code <?xml encoding="...">}), then falls back to
     * {@see mb_detect_encoding()} with a curated detection order.
     *
     * @param string $content Raw XML content.
     *
     * @return string Canonical encoding name (e.g. "UTF-8", "ISO-8859-1").
     */
    private function detectXmlEncoding(string $content): string
    {
        // 1. Check XML declaration: <?xml version="1.0" encoding="..."
        if (preg_match('/^<\?xml[^>]+encoding=["\']([^"\']+)["\']/i', $content, $matches)) {
            $declared = mb_strtoupper(trim($matches[1]), 'UTF-8');
            // Normalize common aliases
            $aliases = [
                'LATIN1'       => 'ISO-8859-1',
                'LATIN-1'      => 'ISO-8859-1',
                'ISO-LATIN-1'  => 'ISO-8859-1',
                'WINDOWS-1252' => 'Windows-1252',
                'CP1252'       => 'Windows-1252',
            ];
            return $aliases[$declared] ?? $declared;
        }

        // 2. Auto-detect from byte content
        $detected = mb_detect_encoding($content, self::ENCODING_DETECT_ORDER, true);

        return $detected ?: 'UTF-8';
    }

    // -----------------------------------------------------------------------
    // Multibyte string helpers
    // -----------------------------------------------------------------------

    /**
     * Checks whether a string ends with a given suffix using
     * multibyte-safe comparison.
     *
     * @param string $haystack The string to search in.
     * @param string $needle   The suffix to check for.
     *
     * @return bool True if $haystack ends with $needle.
     */
    private function mbEndsWith(string $haystack, string $needle): bool
    {
        $needleLen = mb_strlen($needle, 'UTF-8');
        if ($needleLen === 0) {
            return true;
        }
        return mb_substr($haystack, -$needleLen, null, 'UTF-8') === $needle;
    }

    // -----------------------------------------------------------------------
    // XML parsing (DOMDocument)
    // -----------------------------------------------------------------------

    /**
     * Validates whether a DOMDocument represents a DMARC aggregate report.
     * Checks for: root element {@code <feedback>}, child elements
     * {@code <report_metadata>}, {@code <policy_published>} and at least
     * one {@code <record>}.
     *
     * @param \DOMDocument $doc Parsed XML document to validate.
     *
     * @return bool True if the document has a valid DMARC report structure.
     */
    private function isDmarcReport(\DOMDocument $doc): bool
    {
        $root = $doc->documentElement;
        if ($root === null || $root->localName !== 'feedback') {
            return false;
        }

        return $this->firstChildElement($root, 'report_metadata') !== null
            && $this->firstChildElement($root, 'policy_published') !== null
            && $doc->getElementsByTagName('record')->length > 0;
    }

    /**
     * Parses a DMARC aggregate report XML and returns one JSON line per
     * {@code <record>} element. Strips XML namespaces (e.g. DMARC 2.0 from
     * GMX) before parsing to allow simple tag-name-based element access.
     *
     * Validates the XML structure before processing: root element must be
     * {@code <feedback>} and must contain {@code <report_metadata>},
     * {@code <policy_published>} and at least one {@code <record>}.
     *
     * @param string $xmlString UTF-8 encoded DMARC aggregate report XML.
     *
     * @return string[] Array of JSON-encoded lines, one per DMARC record.
     *                  Empty array if the XML is not a DMARC report.
     *
     * @throws \RuntimeException If the XML cannot be parsed.
     */
    private function parseDmarcXml(string $xmlString): array
    {
        // Strip XML namespace — some reporters (e.g. GMX) use
        // xmlns="urn:ietf:params:xml:ns:dmarc-2.0" which complicates
        // element access without namespace prefix.
        $xmlString = preg_replace('/\s+xmlns="[^"]*"/u', '', $xmlString);

        $doc = new \DOMDocument('1.0', 'UTF-8');
        $prev = libxml_use_internal_errors(true);

        if (!$doc->loadXML($xmlString)) {
            $errors = libxml_get_errors();
            libxml_clear_errors();
            libxml_use_internal_errors($prev);
            throw new \RuntimeException($errors[0]->message ?? 'unknown XML error');
        }

        libxml_clear_errors();
        libxml_use_internal_errors($prev);

        // Validate DMARC aggregate report structure
        if (!$this->isDmarcReport($doc)) {
            $this->log->info('XML is not a DMARC aggregate report — skipping', [
                'root' => $doc->documentElement?->localName ?? '(none)',
            ]);
            return [];
        }

        $lines = [];

        $reportId  = $this->domText($doc, 'report_metadata/report_id');
        $orgName   = $this->domText($doc, 'report_metadata/org_name');
        $dateBegin = (int) $this->domText($doc, 'report_metadata/date_range/begin');
        $ts        = $this->timestampToIso8601($dateBegin);
        $domain    = $this->domText($doc, 'policy_published/domain');
        $policy    = $this->domText($doc, 'policy_published/p');

        $records = $doc->getElementsByTagName('record');

        foreach ($records as $record) {
            $line = [
                'ts'            => $ts,
                'report_id'     => $reportId,
                'org_name'      => $orgName,
                'domain'        => $domain,
                'policy'        => $policy,
                'source_ip'     => $this->nodeText($record, 'row/source_ip'),
                'count'         => (int) $this->nodeText($record, 'row/count'),
                'disposition'   => $this->nodeText($record, 'row/policy_evaluated/disposition'),
                'dkim_align'    => $this->nodeText($record, 'row/policy_evaluated/dkim'),
                'spf_align'     => $this->nodeText($record, 'row/policy_evaluated/spf'),
                'header_from'   => $this->nodeText($record, 'identifiers/header_from'),
                'envelope_from' => $this->nodeText($record, 'identifiers/envelope_from')
                                    ?: $this->nodeText($record, 'identifiers/envelope_to'),
                'dkim_domain'   => $this->nodeText($record, 'auth_results/dkim/domain'),
                'dkim_result'   => $this->nodeText($record, 'auth_results/dkim/result'),
                'spf_domain'    => $this->nodeText($record, 'auth_results/spf/domain'),
                'spf_result'    => $this->nodeText($record, 'auth_results/spf/result'),
            ];

            $lines[] = json_encode($line, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        }

        return $lines;
    }

    /**
     * Converts a Unix timestamp to an ISO 8601 UTC string.
     * Returns the current UTC time if the timestamp is zero or negative.
     *
     * @param int $timestamp Unix timestamp (seconds since epoch).
     *
     * @return string ISO 8601 formatted datetime (e.g. "2026-02-19T00:00:00Z").
     */
    private function timestampToIso8601(int $timestamp): string
    {
        if ($timestamp > 0) {
            $dt = (new \DateTimeImmutable())->setTimestamp($timestamp)->setTimezone(new \DateTimeZone('UTC'));
        } else {
            $dt = new \DateTimeImmutable('now', new \DateTimeZone('UTC'));
        }
        return $dt->format('Y-m-d\TH:i:s\Z');
    }

    /**
     * Resolves a slash-separated element path relative to the document's
     * root element and returns the text content of the target node.
     *
     * @param \DOMDocument $doc  The parsed XML document.
     * @param string       $path Slash-separated tag path (e.g. "report_metadata/org_name").
     *
     * @return string Trimmed text content, or empty string if the path does not exist.
     */
    private function domText(\DOMDocument $doc, string $path): string
    {
        $node = $doc->documentElement;
        foreach (explode('/', $path) as $tag) {
            $node = $this->firstChildElement($node, $tag);
            if ($node === null) {
                return '';
            }
        }
        return trim($node->textContent);
    }

    /**
     * Resolves a slash-separated element path relative to a given parent
     * element and returns the text content of the target node.
     *
     * @param \DOMElement $parent Starting element for the path traversal.
     * @param string      $path   Slash-separated tag path (e.g. "row/source_ip").
     *
     * @return string Trimmed text content, or empty string if the path does not exist.
     */
    private function nodeText(\DOMElement $parent, string $path): string
    {
        $node = $parent;
        foreach (explode('/', $path) as $tag) {
            $node = $this->firstChildElement($node, $tag);
            if ($node === null) {
                return '';
            }
        }
        return trim($node->textContent);
    }

    /**
     * Returns the first direct child element with the given tag name,
     * or null if no such child exists.
     *
     * @param \DOMNode $parent  Parent node to search within.
     * @param string   $tagName Local tag name to match.
     *
     * @return \DOMElement|null The first matching child element.
     */
    private function firstChildElement(\DOMNode $parent, string $tagName): ?\DOMElement
    {
        foreach ($parent->childNodes as $child) {
            if ($child instanceof \DOMElement && $child->localName === $tagName) {
                return $child;
            }
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    /**
     * Appends JSON lines to the output file. Creates the parent directory
     * if it does not exist. The file handle is always closed, even on error.
     *
     * @param string[] $jsonLines JSON-encoded lines to write.
     *
     * @throws \RuntimeException If the output file cannot be opened.
     */
    private function writeJsonLines(array $jsonLines): void
    {
        $outputDir = dirname(self::OUTPUT_FILE);
        if (!is_dir($outputDir)) {
            mkdir($outputDir, 0750, true);
        }

        $fp = fopen(self::OUTPUT_FILE, 'a');
        if ($fp === false) {
            throw new \RuntimeException('Failed to open output file: ' . self::OUTPUT_FILE);
        }

        try {
            foreach ($jsonLines as $line) {
                fwrite($fp, $line . "\n");
            }
        } finally {
            fclose($fp);
        }

        $this->log->info('Records written', [
            'count' => count($jsonLines),
            'file'  => self::OUTPUT_FILE,
        ]);
    }
}

// ===========================================================================
// Bootstrap
// ===========================================================================

$dryRun = in_array('--dry-run', $argv, true);

$formatter = new LineFormatter("[%datetime%] [%level_name%] %message% %context%\n", 'Y-m-d H:i:s', false, true);
$streamHandler = new StreamHandler('php://stderr', Logger::DEBUG);
$streamHandler->setFormatter($formatter);
// Dry-run: full output for interactive debugging.
// Normal:  FingersCrossedHandler buffers INFO, flushes only on WARNING+.
$handler = $dryRun
    ? $streamHandler
    : new FingersCrossedHandler($streamHandler, Logger::WARNING);
$log = new Logger('dmarc');
$log->pushHandler($handler);

$parser = new DmarcReportParser($log, $dryRun);

exit($parser->run());

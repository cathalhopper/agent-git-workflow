# Project scans for a deterministic simulation whose behaviour is pinned by
# golden hashes. Copy to scripts\finish-project.ps1 to activate.
#
# The PowerShell twin of finish-project.sh in this directory. That file's header
# carries what the scan looks at and why each of its three exclusions exists; the
# two must behave identically.
#
#   .\scripts\finish.ps1 -Pr -Declare golden-hash -Testing "..."

function Invoke-ProjectScans {
    $exclude = @(':!*.lock', ':!package-lock.json', ':!crates/*/src/**', ':!crates/*/tests/fixtures/**')

    $paths = @(git diff --name-only "origin/$($script:BaseName)...HEAD" |
               Where-Object { $_ -imatch '(^|/)golden/|\.hash$' } |
               Where-Object { $_ -inotmatch '(^|/)tests/fixtures/' })

    $hexHit = $false
    foreach ($raw in @(git diff "origin/$($script:BaseName)...HEAD" -U0 -- $exclude)) {
        if ($raw -like '+++ *' -or $raw -like '--- *') { continue }
        if (($raw.StartsWith('+') -or $raw.StartsWith('-')) -and $raw -cmatch '\b[0-9a-f]{64}\b') {
            $hexHit = $true
            break
        }
    }

    if ($paths.Count -eq 0 -and -not $hexHit) { return }

    if ($paths.Count -eq 0 -and $hexHit) {
        $paths = @(git diff --name-only "origin/$($script:BaseName)...HEAD" -G'[0-9a-f]{64}' -- $exclude)
    }

    if (Test-Declared 'golden-hash') {
        Add-Finding 'golden hash' 'moved, declared intended with -Declare golden-hash'
        Add-Note 'Golden hash moved; declared intended. This is a simulation-version bump.'
        return
    }

    $shown = if ($paths.Count -gt 0) { ($paths | ForEach-Object { "  $_" }) -join "`n" }
             else { '  (64-hex values changed in the diff)' }

    Stop-Now 'this branch appears to move a golden hash' @(
        'the pinned golden hash defines a simulation version. Moving it is a version bump,',
        'not an incidental test update, and re-pinning silently invalidates every result',
        'recorded against the old one.',
        '',
        $shown,
        '',
        'If the change was intended, say so and it goes into the pull request body:',
        '  .\scripts\finish.ps1 -Pr -Declare golden-hash -Testing "..."',
        '',
        'If it was not intended, the simulation moved when you did not think you were',
        'touching it. That is a stop-and-investigate, not a re-pin')
}

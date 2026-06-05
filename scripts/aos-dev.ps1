param(
  [Parameter(Mandatory=$true)]
  [ValidateSet(
    "status",
    "snapshot",
    "build-agent",
    "build-agent-source",
    "build-app",
    "up",
    "restart-app",
    "source-dev-up",
    "binary-up",
    "sync-agent-source",
    "clean-exited-runtimes",
    "prune-dangling-images"
  )]
  [string]$Action
)

$ErrorActionPreference = "Stop"

$ComposeFile = "docker-compose.aos-dev.yml"
$ProjectName = "aos_saas"
$AgentSourceVolume = if ($env:AOS_AGENT_DEV_SOURCE_VOLUME) { $env:AOS_AGENT_DEV_SOURCE_VOLUME } else { "aos_saas_agent_source" }
$AgentSourcePath = if ($env:AOS_AGENT_DEV_SOURCE_PATH) { $env:AOS_AGENT_DEV_SOURCE_PATH } else { "/agent-source" }

function Invoke-AosCompose {
  docker compose -p $ProjectName -f $ComposeFile @args
}

function Get-DockerImageShortId {
  param([string]$ImageRef)

  $imageId = (docker image inspect $ImageRef --format "{{.Id}}" 2>$null)
  if ($LASTEXITCODE -eq 0 -and $imageId) {
    return $imageId.Replace("sha256:", "").Substring(0, 12)
  }

  return $null
}

function Invoke-AosSnapshot {
  Write-Host ""
  Write-Host "=== AOS DEV SNAPSHOT ==="

  Write-Host ""
  Write-Host "--- Volumes ---"
  docker volume ls | Select-String "aos_saas"

  Write-Host ""
  Write-Host "--- Compose services ---"
  Invoke-AosCompose ps

  Write-Host ""
  Write-Host "--- Conversations count ---"
  docker exec aos-openhands-postgres psql -U openhands -d openhands -c "SELECT COUNT(*) AS conversations FROM conversation_metadata;" 2>$null

  Write-Host ""
  Write-Host "--- Latest conversations ---"
  docker exec aos-openhands-postgres psql -U openhands -d openhands -c "SELECT conversation_id,llm_model,sandbox_id,created_at FROM conversation_metadata ORDER BY created_at DESC LIMIT 10;" 2>$null

  Write-Host ""
  Write-Host "--- Agent images ---"

  $knownImages = @{}
  foreach ($imageRef in @("aos-agent-server:dev", "aos-agent-server:source-dev")) {
    $shortId = Get-DockerImageShortId $imageRef
    if ($shortId) {
      $knownImages[$shortId] = $imageRef
      Write-Host "$imageRef -> $shortId"
    } else {
      Write-Host "$imageRef -> NOT_FOUND"
    }
  }

  Write-Host ""
  Write-Host "--- Agent runtimes ---"
  $runtimes = docker ps -a --filter "name=oh-agent-server" --format "{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"
  if (-not $runtimes) {
    Write-Host "No oh-agent-server runtimes found."
  } else {
    $runtimes | ForEach-Object {
      $p = $_ -split "\|", 4
      $name = $p[0]
      $image = $p[1]
      $status = $p[2]
      $ports = $p[3]

      $runtimeImageId = (docker inspect $name --format "{{.Image}}" 2>$null)
      $runtimeShortImageId = if ($runtimeImageId) { $runtimeImageId.Replace("sha256:", "").Substring(0, 12) } else { "unknown" }

      $match = if ($knownImages.ContainsKey($runtimeShortImageId)) {
        "MATCH:" + $knownImages[$runtimeShortImageId]
      } else {
        "OLD_RUNTIME_IMAGE"
      }

      [PSCustomObject]@{
        Name = $name
        Image = $image
        ImageId = $runtimeShortImageId
        Match = $match
        Status = $status
        Ports = $ports
      }
    } | Format-Table -AutoSize
  }

  Write-Host ""
  Write-Host "--- Main containers ---"
  docker ps -a --filter "name=aos-openhands" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

  Write-Host ""
  Write-Host "=== END SNAPSHOT ==="
}

function Sync-AosAgentSource {
  $sourcePath = Join-Path (Get-Location) "vendor\software-agent-sdk"

  if (-not (Test-Path $sourcePath)) {
    throw "Source path not found: $sourcePath"
  }

  Write-Host ""
  Write-Host "--- Syncing agent source into Docker volume ---"
  Write-Host "Source: $sourcePath"
  Write-Host "Volume: $AgentSourceVolume"

  docker volume create $AgentSourceVolume | Out-Null

  docker run --rm `
    -v "${sourcePath}:/src:ro" `
    -v "${AgentSourceVolume}:/dst" `
    alpine sh -c "rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true; cp -a /src/. /dst/"

  Write-Host "Agent source synced."
}

function Build-AosAgentSourceImage {
  docker build `
    -f vendor/software-agent-sdk/openhands-agent-server/openhands/agent_server/docker/Dockerfile `
    --target source `
    -t aos-agent-server:source-dev `
    vendor/software-agent-sdk
}

function Use-AosSourceDevEnv {
  $env:AOS_AGENT_IMAGE = "aos-agent-server"
  $env:AOS_AGENT_TAG = "source-dev"
  $env:AOS_AGENT_TARGET = "source"
  $env:AOS_AGENT_DEV_SOURCE_VOLUME = $AgentSourceVolume
  $env:AOS_AGENT_DEV_SOURCE_PATH = $AgentSourcePath
}

function Use-AosBinaryEnv {
  $env:AOS_AGENT_IMAGE = "aos-agent-server"
  $env:AOS_AGENT_TAG = "dev"
  $env:AOS_AGENT_TARGET = "binary"
  $env:AOS_AGENT_DEV_SOURCE_VOLUME = ""
  $env:AOS_AGENT_DEV_SOURCE_PATH = "/agent-source"
}

switch ($Action) {
  "status" {
    Invoke-AosSnapshot
  }

  "snapshot" {
    Invoke-AosSnapshot
  }

  "build-agent" {
    Invoke-AosSnapshot
    Invoke-AosCompose --profile build build agent-server-image
    docker image prune -f --filter "dangling=true"
    Invoke-AosSnapshot
  }

  "build-agent-source" {
    Invoke-AosSnapshot
    Build-AosAgentSourceImage
    docker image prune -f --filter "dangling=true"
    Invoke-AosSnapshot
  }

  "build-app" {
    Invoke-AosSnapshot
    Invoke-AosCompose build openhands
    docker image prune -f --filter "dangling=true"
    Invoke-AosSnapshot
  }

  "up" {
    Invoke-AosCompose up -d
    Invoke-AosSnapshot
  }

  "restart-app" {
    Invoke-AosSnapshot
    Invoke-AosCompose up -d --no-deps --force-recreate openhands
    Invoke-AosSnapshot
  }

  "source-dev-up" {
    Invoke-AosSnapshot
    Build-AosAgentSourceImage
    Sync-AosAgentSource
    Use-AosSourceDevEnv
    Invoke-AosCompose up -d --no-deps --force-recreate openhands
    Invoke-AosSnapshot
  }

  "binary-up" {
    Invoke-AosSnapshot
    Use-AosBinaryEnv
    Invoke-AosCompose up -d --no-deps --force-recreate openhands
    Invoke-AosSnapshot
  }

  "sync-agent-source" {
    Sync-AosAgentSource
  }

  "clean-exited-runtimes" {
    Invoke-AosSnapshot

    Write-Host ""
    Write-Host "--- Cleaning stopped agent runtimes only ---"

    $containers = @()
    $containers += docker ps -aq --filter "name=oh-agent-server" --filter "status=exited"
    $containers += docker ps -aq --filter "name=oh-agent-server" --filter "status=created"
    $containers += docker ps -aq --filter "name=oh-agent-server" --filter "status=dead"

    $containers = $containers | Where-Object { $_ } | Sort-Object -Unique

    if (-not $containers) {
      Write-Host "No stopped oh-agent-server runtimes to remove."
    } else {
      $containers | ForEach-Object {
        Write-Host "Removing stopped runtime container: $_"
        docker rm $_
      }
    }

    Invoke-AosSnapshot
  }

  "prune-dangling-images" {
    docker image prune -f --filter "dangling=true"
  }
}

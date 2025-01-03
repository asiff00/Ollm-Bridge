<#
.SYNOPSIS
    Creates symbolic links for Ollama models to enhance LM Studio compatibility.

.DESCRIPTION
    Ollm Bridge creates symbolic links within model-specific subdirectories inside a top-level
    'hugging-quants' directory, facilitating the use of Ollama models within LM Studio.
    It identifies the necessary model files (blobs) by examining manifest files from both
    'registry.ollama.ai' and 'hf.co'.

.NOTES
    Version: 0.6
#>

#region Configuration

# Determine the base directory for Ollama models.
# If the environment variable OLLAMA_MODELS is set, use it.
# Otherwise, default to the standard Ollama models directory in the user's profile.
if ($env:OLLAMA_MODELS) {
    # If the environment variable ends with a backslash, use it as is.
    # Otherwise, add a trailing backslash.
    $OllamaBaseDir = if ($env:OLLAMA_MODELS.EndsWith('\')) { $env:OLLAMA_MODELS } else { "$($env:OLLAMA_MODELS)\" }
} else {
    # Default Ollama models directory.
    $OllamaBaseDir = "$env:USERPROFILE\.ollama\models\"
}

# Define the base directories where Ollama stores manifest files.
# These manifests contain metadata about the models.
$ManifestBaseDirs = @(
    (Join-Path -Path $OllamaBaseDir -ChildPath "manifests\registry.ollama.ai"), # Manifests from the default Ollama registry.
    (Join-Path -Path $OllamaBaseDir -ChildPath "manifests\hf.co")              # Manifests from Hugging Face.
)
# Define the directory where Ollama stores the actual model files (blobs).
$BlobDir = Join-Path -Path $OllamaBaseDir -ChildPath "blobs"

# Define the base directory where the symbolic links will be created.
# This 'hugging-quants' directory will be created inside the Ollama base directory.
$HuggingQuantsDir = Join-Path -Path $OllamaBaseDir -ChildPath "hugging-quants"

#endregion

#region Helper Functions

# Function to write informational messages to the console in green.
function Write-Info {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message # The message to be displayed.
    )
    Write-Host -ForegroundColor Green $Message
}

# Function to write warning messages to the console in yellow.
function Write-WarningMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message # The warning message to be displayed.
    )
    Write-Host -ForegroundColor Yellow "Warning: $Message"
}

# Function to ensure a directory exists. If it doesn't, it creates it.
function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path # The path of the directory to ensure.
    )
    # Check if the directory exists.
    if (-not (Test-Path -Path $Path)) {
        Write-Info "Creating directory: '$Path'"
        # Create the directory.
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

# Function to create a symbolic link.
function Create-SymbolicLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LinkPath,   # The path where the symbolic link will be created.
        [Parameter(Mandatory = $true)]
        [string]$TargetPath  # The path to the original file or directory the link will point to.
    )
    # Check if the symbolic link already exists.
    if (-not (Test-Path -Path $LinkPath)) {
        Write-Info "Creating symbolic link: '$LinkPath' -> '$TargetPath'"
        # Create the symbolic link.
        New-Item -ItemType SymbolicLink -Path $LinkPath -Value $TargetPath | Out-Null
    } else {
        Write-Info "Symbolic link already exists: '$LinkPath'"
    }
}

# Function to construct the full path to a blob file given its digest.
function Get-BlobPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Digest # The digest of the blob (e.g., "sha256:abcdef...").
    )
    # Remove the "sha256:" prefix and construct the full path.
    return Join-Path -Path $BlobDir -ChildPath ('sha256-' + ($Digest -replace 'sha256:', ''))
}

#endregion

#region Script Execution

Write-Host ""
Write-Host "Ollm Bridge v 0.6"
Write-Host "-----------------"
Write-Host ""
Write-Host "Configuration:"
Write-Host "  Ollama Base Directory: '$OllamaBaseDir'"
Write-Host "  Blob Directory: '$BlobDir'"
Write-Host "  Hugging Quants Directory: '$HuggingQuantsDir'"
Write-Host "  Manifest Base Directories:"
$ManifestBaseDirs | ForEach-Object { Write-Host "    - $_" }
Write-Host ""

# Check if the Ollama base model directory exists.
if (Test-Path $OllamaBaseDir) {
    Write-Info "Ollama Base Directory Confirmed."
} else {
    Write-Error "Ollama Base Directory '$OllamaBaseDir' not found. Please ensure the OLLAMA_MODELS environment variable is set correctly or that Ollama has been initialized."
    exit 1
}

# Ensure the base hugging-quants directory exists.
Ensure-Directory -Path $HuggingQuantsDir

# Process manifests to create symbolic links.
Write-Host "Processing Manifests..."
# Iterate through each manifest base directory.
foreach ($manifestBaseDir in $ManifestBaseDirs) {
    Write-Host ""
    # Check if the manifest base directory exists.
    if (Test-Path $manifestBaseDir) {
        # Get all manifest files recursively within the current base directory.
        $manifestFiles = Get-ChildItem -Path $manifestBaseDir -Recurse -File -Force -ErrorAction SilentlyContinue
        # Process each manifest file.
        if ($manifestFiles) {
            foreach ($manifestFile in $manifestFiles) {
                try {
                    # Read the content of the manifest file and convert it from JSON.
                    $manifestContent = Get-Content -Path $manifestFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-WarningMessage "Error reading or parsing JSON file: '$($manifestFile.FullName)'. Skipping."
                    continue
                }

                # Check if the manifest contains the 'config.digest'.
                if (-not $manifestContent.config.digest) {
                    Write-WarningMessage "Manifest '$($manifestFile.FullName)' does not contain 'config.digest'. Skipping."
                    continue
                }
                # Get the path to the model's configuration file (blob).
                $modelConfigPath = Get-BlobPath -Digest $manifestContent.config.digest

                try {
                    # Read the content of the model config file and convert it from JSON.
                    $modelConfig = Get-Content -Path $modelConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-WarningMessage "Error reading or parsing config file: '$modelConfigPath'. Skipping model."
                    continue
                }

                # Find the blob containing the actual model data within the layers.
                $modelFileBlob = $null
                foreach ($layer in $manifestContent.layers) {
                    if ($layer.mediaType -like "*model") {
                        $modelFileBlob = Get-BlobPath -Digest $layer.digest
                        break
                    }
                }

                # If no model layer is found, skip this manifest.
                if (-not $modelFileBlob) {
                    Write-WarningMessage "No 'model' layer found in manifest: '$($manifestFile.FullName)'. Skipping."
                    continue
                }

                # Extract model information from the manifest and config.
                $modelName = Split-Path -Path $manifestFile.DirectoryName -Leaf # Get the model name from the directory name.
                $modelQuant = $modelConfig.file_type                           # Get the quantization type.
                $modelExt = $modelConfig.model_format                           # Get the model file extension.
                $modelTrainedOn = $modelConfig.model_type                       # Get information about the training data.

                Write-Host ""
                Write-Host "  Model Name: '$modelName'"
                Write-Host "    Quantization: '$modelQuant'"
                Write-Host "    Extension: '$modelExt'"
                Write-Host "    Trained On: '$modelTrainedOn'"

                # Define the path for the model-specific subdirectory within 'hugging-quants'.
                $modelHuggingQuantsDir = Join-Path -Path $HuggingQuantsDir -ChildPath $modelName
                # Ensure the model-specific subdirectory exists.
                Ensure-Directory -Path $modelHuggingQuantsDir

                # Create the symbolic link to the model blob file.
                $linkPath = Join-Path -Path $modelHuggingQuantsDir -ChildPath "$($modelName)-$($modelTrainedOn)-$($modelQuant).$($modelExt)"
                Create-SymbolicLink -LinkPath $linkPath -TargetPath $modelFileBlob

            }
        } else {
            Write-Host "  No manifest files found in '$manifestBaseDir'."
        }
    } else {
        Write-WarningMessage "Manifest directory not found: '$manifestBaseDir'"
    }
}

Write-Host ""
Write-Host "---------------------"
Write-Host -ForegroundColor Green "Ollm Bridge complete."
Write-Host "---------------------"
Write-Host ""
Write-Host -ForegroundColor Yellow "Set LM Studio's Models Directory to:" -NoNewline
Write-Host -ForegroundColor Cyan " '$($OllamaBaseDir)'"
Write-Host ""

#endregion
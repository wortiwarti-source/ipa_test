(function () {
  "use strict";

  const loginScreen = document.getElementById("login-screen");
  const dashboardScreen = document.getElementById("dashboard-screen");
  const operationStatus = document.getElementById("operation-status");
  const operationDetails = document.getElementById("operation-details");
  const operationIndicator = document.getElementById("operation-indicator");
  const moveButton = document.getElementById("move-button");
  const restoreButton = document.getElementById("restore-button");
  const chooseDirectoryButton = document.getElementById("choose-directory");
  const config = CONFIG;
  const nativePlugin = window.Capacitor &&
    window.Capacitor.Plugins &&
    window.Capacitor.Plugins.FileAccessPlugin;
  let busy = false;

  document.getElementById("login-form").addEventListener("submit", function (event) {
    event.preventDefault();
    loginScreen.hidden = true;
    dashboardScreen.hidden = false;
    refreshDashboard();
  });

  document.getElementById("back-button").addEventListener("click", function () {
    dashboardScreen.hidden = true;
    loginScreen.hidden = false;
    setOperationStatus("Ready. Choose an operation to begin.", "idle");
  });

  moveButton.addEventListener("click", function () {
    runOperation("move");
  });

  restoreButton.addEventListener("click", function () {
    runOperation("restore");
  });

  chooseDirectoryButton.addEventListener("click", async function () {
    if (!nativePlugin || typeof nativePlugin.chooseDirectory !== "function") {
      showError("The iOS folder picker is unavailable in this environment.");
      return;
    }

    try {
      const selected = await nativePlugin.chooseDirectory();
      document.getElementById("access-location").textContent =
        "iOS-granted folder: " + selected.displayName +
        " · configured path will be appended";
      await refreshDashboard();
      setOperationStatus("Folder permission granted. Destination checks have been refreshed.", "success");
    } catch (error) {
      showError(error);
    }
  });

  document.getElementById("target-bundle").textContent = config.targetBundleID;
  document.getElementById("target-path").textContent = config.targetRelativePath;
  if (nativePlugin) {
    chooseDirectoryButton.hidden = false;
    document.getElementById("access-location").textContent =
      "App sandbox unless an iOS folder is explicitly selected.";
  }

  async function refreshDashboard() {
    const sources = await Promise.all([
      checkWebResource(config.moveResource),
      checkWebResource(config.restoreResource)
    ]);
    renderSourceStatus("move", sources[0]);
    renderSourceStatus("restore", sources[1]);
  }

  async function checkWebResource(resource) {
    try {
      const response = await fetch(resource, { cache: "no-store" });
      if (!response.ok) {
        return { available: false, error: "Resource request failed (HTTP " + response.status + ")." };
      }
      const content = await response.arrayBuffer();
      return { available: true, size: content.byteLength };
    } catch (error) {
      return { available: false, error: error.message || String(error) };
    }
  }

  function renderSourceStatus(operation, result) {
    const prefix = operation === "move" ? "move" : "restore";
    const status = document.getElementById(prefix + "-source-status");
    const size = document.getElementById(prefix + "-source-size");
    status.textContent = result.available ? "AVAILABLE" : "MISSING";
    status.dataset.state = result.available ? "success" : "error";
    size.textContent = result.available
      ? formatBytes(result.size) + (result.size === 0 ? " · empty placeholder" : "")
      : result.error;
  }

  async function runOperation(operation) {
    if (busy) return;
    busy = true;
    setButtonsDisabled(true);
    setOperationStatus("Checking bundled resource and destination access…", "working");
    operationDetails.hidden = true;
    operationDetails.textContent = "";

    try {
      const sourcePath = operation === "move" ? config.moveResource : config.restoreResource;
      const source = await checkWebResource(sourcePath);
      renderSourceStatus(operation, source);
      if (!source.available) {
        throw new Error("Source resource unavailable: " + source.error);
      }

      if (!nativePlugin || typeof nativePlugin.inspect !== "function" ||
          typeof nativePlugin.execute !== "function") {
        throw new Error("Native filesystem access is unavailable in this browser. No file was written.");
      }

      const inspection = await nativePlugin.inspect({
        operation: operation,
        resource: sourcePath,
        relativePath: config.targetRelativePath
      });
      showDetails(inspection);
      if (!inspection.sourceAvailable) {
        throw new Error(inspection.error || "The bundled source could not be validated.");
      }
      if (!inspection.destinationAccessible) {
        throw new Error(inspection.error || "Destination access is not available.");
      }

      if (operation === "restore") {
        const accepted = window.confirm(
          "Restore " + inspection.fileName + " (" + formatBytes(inspection.sourceSize) +
          ") to the verified destination? Existing files will not be overwritten without a separate confirmation."
        );
        if (!accepted) {
          setOperationStatus("Restore cancelled. No file was written.", "idle");
          return;
        }
      }

      let overwrite = false;
      if (inspection.destinationExists) {
        overwrite = window.confirm(
          inspection.fileName + " already exists (" + formatBytes(inspection.destinationSize) +
          "). Replace this verified file?"
        );
        if (!overwrite) {
          setOperationStatus("Operation cancelled. The existing file was left unchanged.", "idle");
          return;
        }
      }

      setOperationStatus("Writing file and verifying the result…", "working");
      const result = await nativePlugin.execute({
        operation: operation,
        resource: sourcePath,
        relativePath: config.targetRelativePath,
        overwrite: overwrite,
        expectedDestination: inspection.destinationFingerprint || null
      });
      showDetails(result);
      if (!result.verified) {
        throw new Error(result.error || "The file could not be verified after writing.");
      }
      setOperationStatus(
        (operation === "move" ? "MOVE" : "RESTORE") + " complete. " +
          formatBytes(result.destinationSize) + " written and verified.",
        "success"
      );
    } catch (error) {
      showError(error);
    } finally {
      busy = false;
      setButtonsDisabled(false);
    }
  }

  function showDetails(result) {
    operationDetails.textContent = JSON.stringify(result, null, 2);
    operationDetails.hidden = false;
  }

  function showError(error) {
    const message = error && error.message ? error.message : String(error);
    setOperationStatus("Operation failed: " + message, "error");
    if (!operationDetails.hidden) {
      operationDetails.textContent += "\n\nError: " + message;
    } else {
      operationDetails.textContent = "Error: " + message;
      operationDetails.hidden = false;
    }
  }

  function setOperationStatus(message, state) {
    operationStatus.textContent = message;
    operationIndicator.dataset.state = state;
  }

  function setButtonsDisabled(disabled) {
    moveButton.disabled = disabled;
    restoreButton.disabled = disabled;
    chooseDirectoryButton.disabled = disabled;
  }

  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) return "Unknown size";
    if (bytes < 1024) return bytes + " bytes";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  }
})();

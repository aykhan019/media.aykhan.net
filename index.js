  // Function to fetch the content of a directory using the GitHub API
  async function getDirectoryContents(path) {
    const response = await fetch(
      `https://api.github.com/repos/Drongo-J/media.aykhan.net/contents/${path}`
    );
    const data = await response.json();
    return data;
  }

  // Function to filter assets (images and videos) from the fetched directory
  function filterAssets(contents) {
    return contents.filter((item) => {
      return (
        item.type === "file" &&
        (item.name.endsWith(".png") ||
          item.name.endsWith(".jpg") ||
          item.name.endsWith(".jpeg") ||
          item.name.endsWith(".gif") ||
          item.name.endsWith(".svg") ||
          item.name.endsWith(".mp4"))
      );
    });
  }

  function convertPath(inputPath) {
    // Split the path by '/'
    const pathArray = inputPath.split("/");

    // Capitalize the first letter of each directory
    const capitalizedPathArray = pathArray.map((directory) => {
      return directory.charAt(0).toUpperCase() + directory.slice(1);
    });

    // Join the array elements with '/' separator
    const convertedPath = capitalizedPathArray.join("/");

    return convertedPath;
  }

  function createFolderTitleHTML(folder) {
    const folderName = convertPath(folder);
    return `<div class="folder-title">${folderName}</div>`;
  }

  function createAssetCardHTML(asset) {
    const assetURL = asset.html_url.replace("https://github.com/Drongo-J/media.aykhan.net/blob/master", "https://media.aykhan.net");
    let assetHTML;

    if (asset.name.endsWith(".mp4")) {
      assetHTML = `
        <div class="card asset-card animate__animated animate__zoomIn" onclick="redirectToImage('${assetURL}')">
          <div class="card-body text-center">
            <div class='content-container'>
              <video controls class="img-fluid">
                <source id="${id}" src="${assetURL}" type="video/mp4">
              </video>
            </div>
            <p class="asset-name">${asset.name}</p>
          </div>
        </div>`;
    } else {
      assetHTML = `
      <div class="card asset-card animate__animated animate__zoomIn" onclick="redirectToImage('${assetURL}')">
        <div class="card-body text-center">
          <div class='content-container'>
            <img src="https://media.aykhan.net/assets/gifs/loading.gif" onload="changeSource('${assetURL}', this)" alt="${asset.name}" class="img-fluid" />
          </div>
          <p class="asset-name">${asset.name
            .split(".")[0]
            .toUpperCase()}</p>
        </div>
      </div>`;
    }

    return assetHTML;
  }
  
  function changeSource(url,img){
    img.src = url;
  }

  function displayAssets(assets) {
    const galleryDiv = document.getElementById("gallery");
    galleryDiv.innerHTML = "";

    const groupedAssets = groupAssetsByFolder(assets);

    Object.keys(groupedAssets).forEach((folder) => {
      const folderContainerHTML = `
        <div class="folder-container">
          ${createFolderTitleHTML(folder)}
          <div class="d-flex flex-wrap animate__animated animate__fadeIn assets-container">
            ${groupedAssets[folder]
              .map((asset) => createAssetCardHTML(asset))
              .join("")}
          </div>
          <h1 class='asset-count'>${groupedAssets[folder].length}</h2>
        </div>
      `;

      galleryDiv.insertAdjacentHTML("beforeend", folderContainerHTML);
    });

    document.getElementById("loading-spinner").style.display = 'none';
  }

  // Function to redirect to images
  function redirectToImage(imageURL) {
    window.location.href = imageURL; // Redirect to the image URL
  }

  // Function to group assets by their folders (paths)
  function groupAssetsByFolder(assets) {
    const groupedAssets = {};

    assets.forEach((asset) => {
      const path = asset.path.split("/"); // Split the path into an array
      const folder = path.slice(0, path.length - 1).join("/"); // Join all elements except the last one to get the folder
      if (!groupedAssets[folder]) {
        groupedAssets[folder] = [];
      }
      groupedAssets[folder].push(asset);
    });

    return groupedAssets;
  }

  // Function to fetch and display the media assets on page load
  document.addEventListener("DOMContentLoaded", async () => {
    try {
      const rootContents = await getDirectoryContents("");
      const mediaFolders = rootContents.filter(
        (item) => item.type === "dir"
      );
      const assets = [];

      // Recursive function to go through all folders and subfolders
      async function exploreFolders(folder) {
        const folderContents = await getDirectoryContents(folder.path);
        const folderAssets = filterAssets(folderContents);
        assets.push(...folderAssets);

        const subFolders = folderContents.filter(
          (item) => item.type === "dir"
        );
        for (const subFolder of subFolders) {
          await exploreFolders(subFolder);
        }
      }

      // Explore all media folders and their subfolders
      for (const mediaFolder of mediaFolders) {
        await exploreFolders(mediaFolder);
      }

      // Display the assets in the gallery
      displayAssets(assets);
    } catch (error) {
      console.error("Error fetching media:", error);
    }
  });
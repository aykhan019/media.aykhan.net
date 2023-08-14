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
  
    const accordionContainer = document.getElementById("folderAccordion");
    accordionContainer.innerHTML = ""; // Clear previous content
  
    Object.keys(groupedAssets).forEach((folder, index) => {
      const folderContainerHTML = `
        <div class="folder-container">
          <div class="accordion" id="folderAccordion${index}">
            <div class="accordion-item">
              <h2 class="accordion-header" id="heading${index}">
                <button
                  class="accordion-button"
                  type="button"
                  data-bs-toggle="collapse"
                  data-bs-target="#collapse${index}"
                  aria-expanded="false"
                  aria-controls="collapse${index}"
                >
                  ${createFolderTitleHTML(folder)}
                  <span class="asset-count">${groupedAssets[folder].length}</span>
                </button>
              </h2>
              <div
                id="collapse${index}"
                class="accordion-collapse collapse"
                aria-labelledby="heading${index}"
                data-bs-parent="#folderAccordion${index}"
              >
                <div class="accordion-body d-flex flex-wrap animate__animated animate__fadeIn assets-container">
                  ${groupedAssets[folder].map((asset) => createAssetCardHTML(asset)).join("")}
                </div>
              </div>
            </div>
          </div>
        </div>
      `;
  
      accordionContainer.insertAdjacentHTML("beforeend", folderContainerHTML);
    });
  
    document.getElementById("loading-spinner").style.display = "none";
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
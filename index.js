// index.js

window.addEventListener('DOMContentLoaded', () => {
    fetchMedia('assets', 'image-gallery', 'image');
  });
  
  function fetchMedia(folder, galleryId, mediaType) {
    fetch(`${folder}/${mediaType}s.json`)
      .then(response => response.json())
      .then(mediaData => {
        const gallery = document.getElementById(galleryId);
  
        mediaData.forEach(media => {
          const mediaItem = document.createElement('div');
          mediaItem.classList.add('media-item');
  
          let mediaElement;
  
          if (mediaType === 'image') {
            mediaElement = document.createElement('img');
            mediaElement.src = `${folder}/${media}`;
            mediaElement.alt = media;
          } else if (mediaType === 'video') {
            mediaElement = document.createElement('video');
            mediaElement.controls = true;
  
            const source = document.createElement('source');
            source.src = `${folder}/${media}`;
            source.type = 'video/mp4';
  
            mediaElement.appendChild(source);
          } else if (mediaType === 'pdf') {
            mediaElement = document.createElement('embed');
            mediaElement.src = `${folder}/${media}`;
            mediaElement.type = 'application/pdf';
            mediaElement.width = '100%';
            mediaElement.height = '600px';
          }
  
          const mediaTitle = document.createElement('p');
          mediaTitle.textContent = media;
  
          mediaItem.appendChild(mediaElement);
          mediaItem.appendChild(mediaTitle);
  
          gallery.appendChild(mediaItem);
        });
      })
      .catch(error => console.error('Error fetching media:', error));
  }
  
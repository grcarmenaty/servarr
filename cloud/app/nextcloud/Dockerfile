# Official Nextcloud image + SMB support, so the servarr media share can be
# mounted as external storage (docs/10-cloud-stack.md).
FROM nextcloud:apache

RUN apt-get update \
 && apt-get install -y --no-install-recommends smbclient libsmbclient libsmbclient-dev \
 && pecl install smbclient \
 && docker-php-ext-enable smbclient \
 && rm -rf /var/lib/apt/lists/*

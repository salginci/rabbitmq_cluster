#!/bin/bash

set -e  # Hata yakalama
source rabbit.env  # rabbitmq.env dosyasını yükle

# Add this section right after line 4 (after source rabbit.env)
echo "🔄 Setting up hosts file..."
# Backup original hosts file
sudo cp /etc/hosts /etc/hosts.backup

# Create new hosts file with required entries
sudo bash -c "cat > /etc/hosts" << EOF
# IPv4 definitions
127.0.0.1 localhost
127.0.0.1 ${SHORTNAME}
${NODE_IP} ${SHORTNAME}
${MASTER_IP} master-node
${WORKER_1_IP} worker1
${WORKER_2_IP} worker2

# IPv6 definitions
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
169.254.169.254 metadata.google.internal metadata
EOF

# Verify the hosts file
echo "🔄 Verifying hosts file configuration:"
cat /etc/hosts

# Test hostname resolution
echo "🔄 Testing hostname resolution..."
if ! ping -c 1 master-node &>/dev/null; then
    echo "⚠️ Warning: Unable to resolve master-node. Adding explicit IP mapping..."
    echo "${MASTER_IP} master-node" | sudo tee -a /etc/hosts
fi

# Create RabbitMQ system user and group first
echo "🔄 Creating RabbitMQ system user and group..."
# Create rabbitmq group if it doesn't exist
if ! getent group rabbitmq >/dev/null; then
    sudo groupadd -f rabbitmq
    echo "✅ Created rabbitmq group"
fi

# Create rabbitmq user if it doesn't exist
if ! id -u rabbitmq >/dev/null 2>&1; then
    sudo useradd -r -g rabbitmq -d /var/lib/rabbitmq -s /bin/false rabbitmq
    echo "✅ Created rabbitmq user"
fi

# Verify user and group exist
if ! id -u rabbitmq >/dev/null 2>&1; then
    echo "❌ Failed to create rabbitmq user"
    exit 1
fi

if ! getent group rabbitmq >/dev/null; then
    echo "❌ Failed to create rabbitmq group"
    exit 1
fi

# Create necessary directories and set permissions
sudo mkdir -p /var/lib/rabbitmq
sudo mkdir -p /var/log/rabbitmq
sudo mkdir -p /etc/rabbitmq
sudo mkdir -p /home/rabbitmq

sudo chown -R rabbitmq:rabbitmq /var/lib/rabbitmq
sudo chown -R rabbitmq:rabbitmq /var/log/rabbitmq
sudo chown -R rabbitmq:rabbitmq /etc/rabbitmq
sudo chown -R rabbitmq:rabbitmq /home/rabbitmq

# Get node type from command line argument
NODE_TYPE=$1

if [ -z "$NODE_TYPE" ]; then
    echo "❌ Node type not specified! Usage: ./install_rabbit.sh [master|worker1|worker2]"
    exit 1
fi

# Set node configuration based on type
echo "🔄 Configuring node as $NODE_TYPE..."
case "$NODE_TYPE" in
    "master")
        NODE_NAME=$MASTER_NODE_NAME
        NODE_IP=$MASTER_IP
        ;;
    "worker1")
        NODE_NAME=$WORKER_1_NODE_NAME
        NODE_IP=$WORKER_1_IP
        ;;
    "worker2")
        NODE_NAME=$WORKER_2_NODE_NAME
        NODE_IP=$WORKER_2_IP
        ;;
    *)
        echo "❌ Invalid node type! Usage: ./install_rabbit.sh [master|worker1|worker2]"
        exit 1
        ;;
esac

echo "✅ Node configuration:"
echo "  - Type: $NODE_TYPE"
echo "  - Name: $NODE_NAME"
echo "  - IP: $NODE_IP"

# Add this section after the NODE_TYPE check and before starting the installation

# Prompt for RabbitMQ admin credentials if not already set
if [ -z "$RABBITMQ_ADMIN_USER" ] || [ -z "$RABBITMQ_ADMIN_PASSWORD" ]; then
    echo "🔄 Please enter RabbitMQ admin credentials:"
    
    # Keep asking until we get a valid username
    while true; do
        read -p "Admin Username (minimum 4 characters): " RABBITMQ_ADMIN_USER
        if [ ${#RABBITMQ_ADMIN_USER} -ge 4 ]; then
            break
        else
            echo "❌ Username must be at least 4 characters long"
        fi
    done
    
    # Keep asking until we get a valid password
    while true; do
        read -s -p "Admin Password (minimum 8 characters): " RABBITMQ_ADMIN_PASSWORD
        echo
        if [ ${#RABBITMQ_ADMIN_PASSWORD} -ge 8 ]; then
            read -s -p "Confirm Password: " RABBITMQ_ADMIN_PASSWORD_CONFIRM
            echo
            if [ "$RABBITMQ_ADMIN_PASSWORD" = "$RABBITMQ_ADMIN_PASSWORD_CONFIRM" ]; then
                break
            else
                echo "❌ Passwords do not match"
            fi
        else
            echo "❌ Password must be at least 8 characters long"
        fi
    done
    
    # Export the variables so they're available throughout the script
    export RABBITMQ_ADMIN_USER
    export RABBITMQ_ADMIN_PASSWORD
    
    # Save to rabbit.env file if user confirms
    read -p "Would you like to save these credentials to rabbit.env? (y/N): " SAVE_CREDS
    if [[ "$SAVE_CREDS" =~ ^[Yy]$ ]]; then
        # Remove old credentials if they exist
        sed -i '/RABBITMQ_ADMIN_USER=/d' rabbit.env
        sed -i '/RABBITMQ_ADMIN_PASSWORD=/d' rabbit.env
        
        # Add new credentials
        echo "RABBITMQ_ADMIN_USER=$RABBITMQ_ADMIN_USER" >> rabbit.env
        echo "RABBITMQ_ADMIN_PASSWORD=$RABBITMQ_ADMIN_PASSWORD" >> rabbit.env
        echo "✅ Credentials saved to rabbit.env"
    fi
fi

echo "🚀 RabbitMQ ve Erlang Kurulum Başlıyor..."
echo "📌 Erlang Version: $ERLANG_VERSION"
echo "📌 RabbitMQ Version: $RABBITMQ_VERSION"
echo "📌 Node Type: $NODE_TYPE"
echo "📌 Node Name: $NODE_NAME"
echo "📌 Node IP: $NODE_IP"

# Gerekli bağımlılıkları yükleyelim
sudo apt update && sudo apt install -y curl wget build-essential

# Check if Erlang is already installed with correct version
echo "🔄 Checking Erlang installation..."
if command -v erl >/dev/null 2>&1; then
    CURRENT_ERLANG_VERSION=$(erl -eval '{ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(Version), halt().' -noshell)
    if [ "$CURRENT_ERLANG_VERSION" = "$ERLANG_VERSION" ]; then
        echo "✅ Erlang $CURRENT_ERLANG_VERSION is already installed"
    else
        echo "⚠️ Found Erlang $CURRENT_ERLANG_VERSION but need $ERLANG_VERSION"
        echo "🔄 Removing existing Erlang installation..."
        sudo rm -f /etc/apt/sources.list.d/erlang*  # Remove Erlang repo
        sudo apt-get remove -y erlang* || true
        sudo apt-get autoremove -y
        sudo rm -rf /usr/lib/erlang
        sudo rm -f /usr/bin/erl
        sudo rm -f /usr/bin/erlc
        INSTALL_ERLANG=true
    fi
else
    INSTALL_ERLANG=true
fi

# Remove any remaining repository files
sudo rm -f /etc/apt/sources.list.d/erlang*
sudo rm -f /etc/apt/sources.list.d/rabbitmq*

# Update package list after removing repos
sudo apt-get update

if [ "$INSTALL_ERLANG" = true ]; then
    echo "🔄 Installing Erlang $ERLANG_VERSION from source..."
    
    # Install build dependencies
    sudo apt-get install -y \
        build-essential \
        autoconf \
        m4 \
        libncurses5-dev \
        libssh-dev \
        unixodbc-dev \
        libgmp3-dev \
        libssl-dev \
        libsctp-dev \
        lksctp-tools \
        ed \
        flex \
        libxml2-utils \
        wget \
        || {
            echo "❌ Failed to install build dependencies"
            exit 1
        }

    # Download and extract Erlang source from GitHub
    echo "🔄 Downloading Erlang source..."
    ERLANG_DOWNLOAD_URL="https://github.com/erlang/otp/archive/OTP-${ERLANG_VERSION}.tar.gz"
    wget -q "$ERLANG_DOWNLOAD_URL" || {
        echo "❌ Failed to download Erlang source"
        echo "URL: $ERLANG_DOWNLOAD_URL"
        exit 1
    }

    tar xzf OTP-${ERLANG_VERSION}.tar.gz || {
        echo "❌ Failed to extract Erlang source"
        exit 1
    }

    cd otp-OTP-${ERLANG_VERSION} || {
        echo "❌ Failed to change to Erlang directory"
        exit 1
    }

    # Configure and build
    ./otp_build autoconf || {
        echo "❌ Failed to run autoconf"
        exit 1
    }

    ./configure --prefix=/usr/local \
        --enable-threads \
        --enable-smp-support \
        --enable-kernel-poll \
        --enable-ssl \
        --with-ssl \
        --enable-crypto \
        || {
            echo "❌ Configure failed"
            exit 1
        }

    make -j$(nproc) || {
        echo "❌ Make failed"
        exit 1
    }

    sudo make install || {
        echo "❌ Make install failed"
        exit 1
    }

    cd ..
    rm -rf otp-OTP-${ERLANG_VERSION}*
fi

# Verify Erlang installation
echo "🔄 Verifying Erlang installation..."
erl -eval '{ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(Version), halt().' -noshell || {
    echo "❌ Erlang installation verification failed"
    exit 1
}

# After verifying Erlang version
echo "🔄 Checking Erlang modules..."
if ! erl -noshell -eval 'case code:ensure_loaded(crypto) of {module,crypto} -> halt(0); _ -> halt(1) end.'; then
    echo "⚠️ Crypto module not found, reinstalling Erlang from source..."
    
    # Remove existing Erlang installation
    sudo rm -f /etc/apt/sources.list.d/erlang*  # Remove Erlang repo
    sudo apt-get remove -y erlang* || true
    sudo apt-get autoremove -y
    sudo rm -rf /usr/lib/erlang
    sudo rm -f /usr/bin/erl
    sudo rm -f /usr/bin/erlc
    
    # Install build dependencies
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        autoconf \
        m4 \
        libncurses5-dev \
        libssh-dev \
        unixodbc-dev \
        libgmp3-dev \
        libssl-dev \
        libsctp-dev \
        lksctp-tools \
        ed \
        flex \
        libxml2-utils \
        wget \
        || {
            echo "❌ Failed to install build dependencies"
            exit 1
        }

    # Download and extract Erlang source
    echo "🔄 Downloading Erlang source..."
    ERLANG_DOWNLOAD_URL="https://github.com/erlang/otp/archive/OTP-${ERLANG_VERSION}.tar.gz"
    wget -q "$ERLANG_DOWNLOAD_URL" || {
        echo "❌ Failed to download Erlang source"
        echo "URL: $ERLANG_DOWNLOAD_URL"
        exit 1
    }

    tar xzf OTP-${ERLANG_VERSION}.tar.gz || {
        echo "❌ Failed to extract Erlang source"
        exit 1
    }

    cd otp-OTP-${ERLANG_VERSION} || {
        echo "❌ Failed to change to Erlang directory"
        exit 1
    }

    # Configure and build
    ./configure --prefix=/usr/local \
        --enable-threads \
        --enable-smp-support \
        --enable-kernel-poll \
        --enable-ssl \
        --with-ssl \
        --enable-crypto \
        || {
            echo "❌ Configure failed"
            exit 1
        }

    make -j$(nproc) || {
        echo "❌ Make failed"
        exit 1
    }

    sudo make install || {
        echo "❌ Make install failed"
        exit 1
    }

    cd ..
    rm -rf otp-OTP-${ERLANG_VERSION}*
fi

# Verify crypto module again
echo "🔄 Verifying crypto module..."
if ! erl -noshell -eval '
    case application:ensure_all_started(crypto) of
        {ok, _} -> 
            io:format("Crypto module working~n"),
            halt(0);
        Error -> 
            io:format("Error: ~p~n", [Error]),
            halt(1)
    end.'; then
    echo "❌ Crypto module verification failed"
    echo "🔍 Checking Erlang installation:"
    dpkg -l | grep erlang
    echo "🔍 Checking crypto module location:"
    find /usr/lib/erlang -name crypto.beam
    exit 1
fi

# RabbitMQ Kurulumu
echo "🔄 RabbitMQ $RABBITMQ_VERSION kuruluyor..."
wget -q https://github.com/rabbitmq/rabbitmq-server/releases/download/v$RABBITMQ_VERSION/rabbitmq-server-generic-unix-$RABBITMQ_VERSION.tar.xz
tar -xf rabbitmq-server-generic-unix-$RABBITMQ_VERSION.tar.xz

# Remove old installation if exists
sudo rm -rf /opt/rabbitmq
sudo rm -f /usr/local/bin/rabbitmqctl
sudo rm -f /usr/local/bin/rabbitmq-server
sudo rm -f /usr/local/bin/rabbitmq-env

# Install RabbitMQ
sudo mv rabbitmq_server-$RABBITMQ_VERSION /opt/rabbitmq

# Create all necessary symbolic links
sudo ln -sf /opt/rabbitmq/sbin/rabbitmqctl /usr/local/bin/rabbitmqctl
sudo ln -sf /opt/rabbitmq/sbin/rabbitmq-server /usr/local/bin/rabbitmq-server
sudo ln -sf /opt/rabbitmq/sbin/rabbitmq-env /usr/local/bin/rabbitmq-env
sudo ln -sf /opt/rabbitmq/sbin/rabbitmq-plugins /usr/local/bin/rabbitmq-plugins

# Clean up downloaded files
rm -f rabbitmq-server-generic-unix-$RABBITMQ_VERSION.tar.xz

# After RabbitMQ installation and before service setup
echo "🔄 Setting up RabbitMQ..."

# Create RabbitMQ configuration directory
sudo mkdir -p /etc/rabbitmq

# Create rabbitmq-env.conf
echo "🔄 Creating RabbitMQ environment configuration..."
sudo tee /etc/rabbitmq/rabbitmq-env.conf << EOF
NODENAME=${NODE_NAME}
NODE_IP_ADDRESS=${NODE_IP}
NODE_PORT=${RABBITMQ_PORT}
RABBITMQ_BASE=/var/lib/rabbitmq
RABBITMQ_CONFIG_FILE=/etc/rabbitmq/rabbitmq
RABBITMQ_LOG_BASE=/var/log/rabbitmq
EOF

# Create rabbitmq.conf
echo "🔄 Creating RabbitMQ main configuration..."
sudo tee /etc/rabbitmq/rabbitmq.conf << EOF
listeners.tcp.default = ${RABBITMQ_PORT}
management.tcp.port = ${RABBITMQ_MANAGEMENT_PORT}
management.tcp.ip = 0.0.0.0

log.file.level = info
log.dir = /var/log/rabbitmq

cluster_partition_handling = ignore
cluster_formation.peer_discovery_backend = classic_config
EOF

# Add node-specific configuration
if [ "$NODE_TYPE" == "master" ]; then
    echo "cluster_formation.classic_config.nodes.1 = ${NODE_NAME}" | sudo tee -a /etc/rabbitmq/rabbitmq.conf
else
    echo "cluster_formation.classic_config.nodes.1 = rabbit@master-node" | sudo tee -a /etc/rabbitmq/rabbitmq.conf
fi

# Set proper permissions for config files
sudo chown -R rabbitmq:rabbitmq /etc/rabbitmq
sudo chmod 644 /etc/rabbitmq/rabbitmq.conf
sudo chmod 644 /etc/rabbitmq/rabbitmq-env.conf

# Create enabled_plugins file
echo "🔄 Creating enabled_plugins file..."
sudo tee /etc/rabbitmq/enabled_plugins << EOF
[rabbitmq_management,rabbitmq_management_agent,rabbitmq_prometheus].
EOF
sudo chown rabbitmq:rabbitmq /etc/rabbitmq/enabled_plugins
sudo chmod 644 /etc/rabbitmq/enabled_plugins

# First, modify the systemd service file
echo "🔄 Creating systemd service file..."
sudo tee /etc/systemd/system/rabbitmq-server.service << EOF
[Unit]
Description=RabbitMQ Server
After=network.target epmd@0.0.0.0.socket
Wants=network.target epmd@0.0.0.0.socket

[Service]
Type=notify
NotifyAccess=all
User=rabbitmq
Group=rabbitmq
UMask=0027
SyslogIdentifier=rabbitmq
LimitNOFILE=65536

Environment=HOME=/var/lib/rabbitmq
Environment=RABBITMQ_HOME=/opt/rabbitmq
Environment=RABBITMQ_BASE=/var/lib/rabbitmq
Environment=RABBITMQ_CONFIG_FILE=/etc/rabbitmq/rabbitmq
Environment=RABBITMQ_ENABLED_PLUGINS_FILE=/etc/rabbitmq/enabled_plugins
Environment=RABBITMQ_LOG_BASE=/var/log/rabbitmq
Environment=RABBITMQ_MNESIA_BASE=/var/lib/rabbitmq/mnesia
Environment=RABBITMQ_NODENAME=${NODE_NAME}
Environment=RABBITMQ_NODE_IP_ADDRESS=${NODE_IP}
Environment=RABBITMQ_NODE_PORT=${RABBITMQ_PORT}
Environment=PATH=/opt/rabbitmq/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8

ExecStartPre=/bin/mkdir -p /var/lib/rabbitmq/mnesia
ExecStartPre=/bin/chown -R rabbitmq:rabbitmq /var/lib/rabbitmq
ExecStartPre=/bin/chmod 755 /var/lib/rabbitmq

ExecStart=/opt/rabbitmq/sbin/rabbitmq-server
ExecStop=/opt/rabbitmq/sbin/rabbitmqctl stop

Restart=on-failure
RestartSec=10
TimeoutStartSec=600

WorkingDirectory=/var/lib/rabbitmq

[Install]
WantedBy=multi-user.target
EOF

# Ensure proper permissions and ownership
echo "🔄 Setting up permissions..."
sudo mkdir -p /var/lib/rabbitmq/mnesia
sudo mkdir -p /var/log/rabbitmq
sudo mkdir -p /etc/rabbitmq
sudo mkdir -p /opt/rabbitmq/var/lib/rabbitmq/mnesia

# Set correct ownership
sudo chown -R rabbitmq:rabbitmq /var/lib/rabbitmq
sudo chown -R rabbitmq:rabbitmq /var/log/rabbitmq
sudo chown -R rabbitmq:rabbitmq /etc/rabbitmq
sudo chown -R rabbitmq:rabbitmq /opt/rabbitmq

# Set correct permissions
sudo chmod 755 /var/lib/rabbitmq
sudo chmod 755 /var/log/rabbitmq
sudo chmod 755 /etc/rabbitmq
sudo chmod 755 /opt/rabbitmq

# Ensure clean state and proper permissions
echo "🔄 Preparing RabbitMQ directories and permissions..."
sudo systemctl stop rabbitmq-server || true
sudo rm -rf /var/lib/rabbitmq/mnesia/*

# Set up Erlang cookie with proper permissions
echo "🔄 Setting up Erlang cookie..."
for COOKIE_PATH in /var/lib/rabbitmq/.erlang.cookie /root/.erlang.cookie /home/rabbitmq/.erlang.cookie; do
    sudo rm -f "$COOKIE_PATH"
    echo "$RABBITMQ_COOKIE" | sudo tee "$COOKIE_PATH" > /dev/null
    sudo chmod 400 "$COOKIE_PATH"
    if [[ "$COOKIE_PATH" == "/var/lib/rabbitmq/.erlang.cookie" ]] || [[ "$COOKIE_PATH" == "/home/rabbitmq/.erlang.cookie" ]]; then
        sudo chown rabbitmq:rabbitmq "$COOKIE_PATH"
    fi
done

# Verify cookie files
echo "🔄 Verifying cookie files..."
for COOKIE_PATH in /var/lib/rabbitmq/.erlang.cookie /root/.erlang.cookie /home/rabbitmq/.erlang.cookie; do
    if [ "$(sudo cat $COOKIE_PATH)" != "$RABBITMQ_COOKIE" ]; then
        echo "❌ Cookie mismatch in $COOKIE_PATH"
        exit 1
    fi
done

# Start RabbitMQ with proper delay
echo "🔄 Starting RabbitMQ..."
sudo systemctl daemon-reload
sudo systemctl restart rabbitmq-server
echo "🔄 Waiting for RabbitMQ to fully start..."
sleep 30

# Set up admin user
echo "🔄 Setting up admin user..."
MAX_RETRIES=5
RETRY_COUNT=0
SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$SUCCESS" = false ]; do
    echo "🔄 Attempting to create admin user (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
    if sudo rabbitmqctl list_users >/dev/null 2>&1; then
        sudo rabbitmqctl delete_user "$RABBITMQ_ADMIN_USER" || true
        if sudo rabbitmqctl add_user "$RABBITMQ_ADMIN_USER" "$RABBITMQ_ADMIN_PASSWORD" && \
           sudo rabbitmqctl set_user_tags "$RABBITMQ_ADMIN_USER" administrator && \
           sudo rabbitmqctl set_permissions -p "/" "$RABBITMQ_ADMIN_USER" ".*" ".*" ".*" && \
           sudo rabbitmqctl delete_user guest || true; then
            SUCCESS=true
            echo "✅ Successfully created admin user"
        fi
    else
        RETRY_COUNT=$((RETRY_COUNT+1))
        echo "⚠️ RabbitMQ not ready yet, waiting before retry..."
        sleep 10
    fi
done

if [ "$SUCCESS" = false ]; then
    echo "❌ Failed to create admin user after $MAX_RETRIES attempts"
    echo "🔍 Checking RabbitMQ status and logs..."
    sudo systemctl status rabbitmq-server
    if ! sudo systemctl is-active rabbitmq-server >/dev/null 2>&1; then
        echo "❌ RabbitMQ failed to start. Last 50 lines of logs:"
        sudo journalctl -u rabbitmq-server -n 50 --no-pager
        exit 1
    fi
fi

# Verify the setup
echo "🔄 Verifying setup..."
sudo rabbitmqctl status
sudo rabbitmqctl list_users

# Worker node ise cluster'a katıl
if [ "$NODE_TYPE" != "master" ]; then
    echo "🔄 Joining cluster as $NODE_TYPE..."
    
    # Önce bağlantıyı kontrol et
    if ! ping -c 3 master-node &>/dev/null; then
        echo "❌ Cannot reach master node. Check network connectivity."
        exit 1
    fi

    # RabbitMQ uygulamasını durdur
    sudo rabbitmqctl stop_app
    
    # Node'u sıfırla
    sudo rabbitmqctl reset
    
    # Cluster'a katılmayı dene
    MAX_RETRIES=5
    RETRY_COUNT=0
    JOINED=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$JOINED" = false ]; do
        echo "🔄 Attempting to join cluster (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
        if sudo rabbitmqctl join_cluster rabbit@master-node; then
            JOINED=true
            echo "✅ Successfully joined the cluster"
        else
            RETRY_COUNT=$((RETRY_COUNT+1))
            echo "⚠️ Join attempt failed, waiting before retry..."
            sleep 10
        fi
    done
    
    if [ "$JOINED" = false ]; then
        echo "❌ Failed to join cluster after $MAX_RETRIES attempts"
        exit 1
    fi
    
    # Uygulamayı başlat
    sudo rabbitmqctl start_app
fi

# Son durum kontrolü
echo "🔄 Final status check..."
sudo rabbitmqctl cluster_status
sudo rabbitmq-plugins list

# Log ve Data Yollarını Belirleme
echo "🔄 RabbitMQ Log & Mnesia Yolları Ayarlanıyor..."
sudo mkdir -p $RABBITMQ_LOG_DIR $RABBITMQ_MNESIA_DIR
sudo chown -R rabbitmq:rabbitmq $RABBITMQ_LOG_DIR $RABBITMQ_MNESIA_DIR

echo "✅ RabbitMQ ve Erlang Kurulumu Tamamlandı!"
echo "📌 RabbitMQ Yönetim Paneli: http://$MASTER_IP:15672"
echo "📌 Kullanıcı Adı: $RABBITMQ_ADMIN_USER"
echo "📌 Şifre: $RABBITMQ_ADMIN_PASSWORD"

echo "🔄 Checking host resolution..."
# Add hosts entries if they don't exist
if ! grep -q "$MASTER_IP.*master-node" /etc/hosts; then
    echo "$MASTER_IP master-node" | sudo tee -a /etc/hosts
fi
if ! grep -q "$WORKER_1_IP.*worker1" /etc/hosts; then
    echo "$WORKER_1_IP worker1" | sudo tee -a /etc/hosts
fi
if ! grep -q "$WORKER_2_IP.*worker2" /etc/hosts; then
    echo "$WORKER_2_IP worker2" | sudo tee -a /etc/hosts
fi

# Add after setting the cookie
echo "🔄 Verifying cookie files..."
if [ "$(sudo cat /var/lib/rabbitmq/.erlang.cookie)" != "$RABBITMQ_COOKIE" ]; then
    echo "❌ Cookie mismatch in /var/lib/rabbitmq/.erlang.cookie"
    exit 1
fi
if [ "$(sudo cat /root/.erlang.cookie)" != "$RABBITMQ_COOKIE" ]; then
    echo "❌ Cookie mismatch in /root/.erlang.cookie"
    exit 1
fi

# Add node name verification and correction
echo "🔄 Verifying node name configuration..."
CURRENT_NODENAME=$(sudo rabbitmqctl status | grep -oP "Node: \K[^,]*" || echo "")
EXPECTED_NODENAME="${NODE_NAME}"

if [ "$CURRENT_NODENAME" != "$EXPECTED_NODENAME" ]; then
    echo "⚠️ Node name mismatch. Current: $CURRENT_NODENAME, Expected: $EXPECTED_NODENAME"
    echo "🔄 Updating node name configuration..."
    
    # Stop RabbitMQ
    sudo systemctl stop rabbitmq-server
    
    # Update the node name in rabbitmq-env.conf
    sudo tee /etc/rabbitmq/rabbitmq-env.conf << EOF
NODENAME=${NODE_NAME}
NODE_IP_ADDRESS=${NODE_IP}
NODE_PORT=${RABBITMQ_PORT}
EOF
    
    # Clear mnesia directory to avoid conflicts
    sudo rm -rf /var/lib/rabbitmq/mnesia/*
    
    # Restart RabbitMQ with new configuration
    sudo systemctl start rabbitmq-server
    sleep 10
    
    # Verify the change
    NEW_NODENAME=$(sudo rabbitmqctl status | grep -oP "Node: \K[^,]*" || echo "")
    if [ "$NEW_NODENAME" != "$EXPECTED_NODENAME" ]; then
        echo "❌ Failed to update node name. Current: $NEW_NODENAME"
        exit 1
    else
        echo "✅ Node name successfully updated to $NEW_NODENAME"
    fi
fi

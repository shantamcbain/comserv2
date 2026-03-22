#!/bin/bash

# Comserv Server Management Script

SERVICE=""
case "$1" in
    dev|development)
        SERVICE="comserv-dev.service"
        PORT="3000"
        shift
        ;;
    prod|production)
        SERVICE="comserv-prod.service"
        PORT="5000"
        shift
        ;;
    *)
        echo "Usage: $0 {dev|prod} {start|stop|restart|status|logs|enable|disable}"
        echo ""
        echo "Server Types:"
        echo "  dev/development  - Development server (port 3000)"
        echo "  prod/production  - Production server (port 5000)"
        echo ""
        echo "Commands:"
        echo "  start    - Start the server"
        echo "  stop     - Stop the server"
        echo "  restart  - Restart the server"
        echo "  status   - Show server status"
        echo "  logs     - Show server logs (real-time)"
        echo "  enable   - Enable auto-start on boot"
        echo "  disable  - Disable auto-start on boot"
        echo ""
        echo "Examples:"
        echo "  $0 dev start     - Start development server"
        echo "  $0 prod restart  - Restart production server"
        echo "  $0 dev logs      - View development server logs"
        exit 1
        ;;
esac

case "$1" in
    start)
        echo "Starting Comserv server ($SERVICE)..."
        sudo systemctl start $SERVICE
        echo "Server started on port $PORT"
        ;;
    stop)
        echo "Stopping Comserv server ($SERVICE)..."
        sudo systemctl stop $SERVICE
        echo "Server stopped"
        ;;
    restart)
        echo "Restarting Comserv server ($SERVICE)..."
        sudo systemctl restart $SERVICE
        echo "Server restarted on port $PORT"
        ;;
    status)
        sudo systemctl status $SERVICE
        ;;
    logs)
        sudo journalctl -u $SERVICE -f
        ;;
    enable)
        echo "Enabling Comserv server ($SERVICE) to start on boot..."
        sudo systemctl enable $SERVICE
        echo "Server enabled for boot startup"
        ;;
    disable)
        echo "Disabling Comserv server ($SERVICE) from starting on boot..."
        sudo systemctl disable $SERVICE
        echo "Server disabled from boot startup"
        ;;
    *)
        echo "Usage: $0 {dev|prod} {start|stop|restart|status|logs|enable|disable}"
        exit 1
        ;;
esac

exit 0
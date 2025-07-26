---
description: Debugging and Troubleshooting Protocols
globs: ["**/*.pm", "**/*.pl", "**/*.t"]
alwaysApply: false
---

# Debugging Protocols

## Log Analysis Priority
1. **Application Logs:** Check `/home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log` first
2. **Error Logs:** Look for recent errors and stack traces
3. **Debug Mode:** Enable debug mode in session for detailed output

## Common Debugging Steps
1. **Reproduce Issue:** Ensure issue is reproducible
2. **Check Recent Changes:** Review recent code modifications
3. **Verify Dependencies:** Ensure all required modules are installed
4. **Database Connectivity:** Test database connections
5. **Permission Issues:** Check file and directory permissions

## Testing Protocol
- **Unit Tests:** Run relevant unit tests first
- **Integration Tests:** Test full workflow
- **Browser Testing:** Always test in actual browser environment
- **Log Monitoring:** Monitor logs during testing

## Performance Issues
- **Database Queries:** Check for slow queries
- **Memory Usage:** Monitor memory consumption
- **Template Rendering:** Check template compilation times
- **Network Latency:** Consider network-related delays
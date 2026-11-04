# The agent's own broker user (task 038), so that the configuration on the agent
# machine opens nothing but the agent's two queues. deploy.sh runs this inside
# the broker container; repeating it changes nothing.
set -eu
rabbitmqctl -q add_user aeroflow-agent "$AGENT_RABBITMQ_PASSWORD" 2>/dev/null \
    || rabbitmqctl -q change_password aeroflow-agent "$AGENT_RABBITMQ_PASSWORD"

# In rabbitmqctl's order: configure (the agent declares its two queues and the
# agent_events exchange), write (it publishes events to that exchange), read (it
# consumes commands and binds the events queue). No write on the default
# exchange: it reaches every queue of the vhost, emergency_commands included.
rabbitmqctl -q set_permissions -p / aeroflow-agent \
    '^agent_(commands|events)$' '^agent_events$' '^agent_(commands|events)$'

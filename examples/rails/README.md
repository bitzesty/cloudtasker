# Example usage with Rails

## Run using the local processing server

1. Install dependencies: `bundle install`
2. Launch the server: `foreman start`
3. Open a Rails console: `rails c`
4. Enqueue workers:
```ruby
DummyWorker.perform_async
```

## Run using Cloud Tasks

1. Ensure that your [Google Cloud SDK](https://cloud.google.com/sdk/docs/quickstarts) is setup.
2. Install dependencies: `bundle install`
3. Start an [ngrok](https://ngrok.com) tunnel: `ngrok http 3000`
4. Edit the [initializer](./config/initializers/cloudtasker.rb) 
    * Add the configuration of your GCP queue
    * Set `config.processor_host` to the ngrok http or https url
    * Set `config.mode` to `:production`
5. Setup your queues on Google Cloud Tasks:
```
# Default and critical queues
rake cloudtasker:setup_queue
rake cloudtasker:setup_queue name=critical
```
6. Launch the server: `foreman start web`
7. Open a Rails console: `rails c`
8. Enqueue workers:
```ruby
DummyWorker.perform_async
```

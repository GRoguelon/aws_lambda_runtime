defmodule AWS.Lambda.Runtime.MixRelease do
  ## Public functions

  def releases(name \\ :lambda) do
    [
      {name,
       [
         # ERTS and the OTP applications come from the Lambda layer mounted at
         # /opt/otp, so the release only carries Elixir + our own code. This is
         # what keeps the function package small enough to stay editable in the
         # console and fast to deploy — but it also means the layer must contain
         # the *exact* OTP version this was built against. The Dockerfile
         # guarantees that by building both from the same stage.
         include_erts: false,
         include_executables_for: [:unix],
         strip_beams: true,
         quiet: true,
         steps: [
           :assemble,
           &AWS.Lambda.Runtime.Release.copy_bootstrap/1,
           &AWS.Lambda.Runtime.Release.copy_release_files/1
         ]
       ]}
    ]
  end
end

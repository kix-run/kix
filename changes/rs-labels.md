+++
kind = "changed"
+++
During a deploy, stall and wait messages now show steps that are not Kubernetes objects in brackets (such as `⟦api-discovery⟧`), matching the rest of Kix's output. They also replace control and invisible characters in object names with their Unicode code points, such as `⟨U+200B⟩`.

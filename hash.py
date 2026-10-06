import base64

# 1. Define the long server network string
# long_string = "JBFijSh3a00F55zp/8r+rQIAAAAUdwcAAAAAAAAAAAD7777W2W4dv8IIijtiqbTPAAosSF4RiC7WThej6szpig=="
long_string = "KRUYAgMVb9ltbKVdZ+irtgIAAADKRB4AAAAAAAAAAAAwIEXtDNAyyZVRcoUcvis1cuj11fzOeq/f0ByU/0kn+A=="


# 2. Decode the Base64 string into its raw binary bytes (64 bytes total)
decoded_bytes = base64.b64decode(long_string)

# 3. Extract the last 32 bytes (this contains your player config footprint)
player_hash_bytes = decoded_bytes[-32:]

# 4. Re-encode those specific 32 bytes back into standard Base64
profile_hash = base64.b64encode(player_hash_bytes).decode('utf-8')


print("Your Recovered Profile Hash:")
print(profile_hash)

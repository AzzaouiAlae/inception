HOME = /home/aazzaoui
run: setup
	docker compose -f srcs/docker-compose.yml up -d

start:
	docker compose -f srcs/docker-compose.yml start

stop:
	docker compose -f srcs/docker-compose.yml stop

setup:
	chmod +x srcs/requirements/tools/setup.sh
	./srcs/requirements/tools/setup.sh

clean:
	docker compose -f srcs/docker-compose.yml down --rmi all --remove-orphans
	
fclean: 
	docker compose -f srcs/docker-compose.yml down --rmi all --volumes --remove-orphans
	-rm -rf srcs/secrets
	-rm -rf $(HOME)/data/
	

re: clean run

fre: fclean run